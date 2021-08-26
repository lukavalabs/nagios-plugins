#!/bin/bash
# Much of this install script has been inspired by the Sandstorm installer (install.sandstorm.io)

if test -z "$BASH_VERSION"; then
  echo "Please run this script using bash, not sh or any other shell." >&2
  exit 1
fi

if test -z "$(type -p xz)"; then
  echo "Please install xz-utils." >&2
  exit 1
fi

if test -z "$(type -p patch)"; then
  echo "Please install the 'patch' command." >&2
  exit 1
fi

# We wrap the entire script in a big function which we only call at the very end, in order to
# protect against the possibility of the connection dying mid-script. This protects us against
# the problem described in this blog post:
#   http://blog.existentialize.com/dont-pipe-to-your-shell.html
_() {
  set -euo pipefail

  # Declare an array so that we can capture the original arguments.
  declare -a ORIGINAL_ARGS

  CURL_USER_AGENT="${CURL_USER_AGENT:-lukava-icinga-install-script}"

  # Define I/O helper functions.
  error() {
    if [ $# != 0 ]; then
      echo -en '\e[0;31m' >&2
      echo "$@" | (fold -s || cat) >&2
      echo -en '\e[0m' >&2
    fi
  }

  fail() {
    local error_code="$1"
    shift
    if [ "${SHOW_FAILURE_MSG:-yes}" = "yes" ] ; then
      echo "*** INSTALLATION FAILED ***" >&2
      echo ""
    fi
    error "$@"
    echo "" >&2
  }

  retryable_curl() {
    # This function calls curl to download a file. If the file download fails, it asks the user if it
    # is OK to retry.
    local CURL_FAILED="no"
    curl -s -A "${CURL_USER_AGENT}" -f "$1" > "$2" || CURL_FAILED="yes"
    if [ "yes" = "${CURL_FAILED}" ] ; then
      if prompt-yesno "Downloading $1 failed. OK to retry?" "yes" ; then
        echo "" >&2
        echo "Download failed. Waiting one second before retrying..." >&2
        sleep 1
        retryable_curl "$1" "$2"
      fi
    fi
  }

  prompt() {
    local VALUE

    # Hack: We read from FD 3 because when reading the script from a pipe, FD 0 is the script, not
    #   the terminal. We checked above that FD 1 (stdout) is in fact a terminal and then dup it to
    #   FD 3, thus we can input from FD 3 here.
    if [ "yes" = "$USE_DEFAULTS" ] ; then
      # Print the default.
      echo "$2"
      return
    fi

    # We use "bold", rather than any particular color, to maximize readability. See #2037.
    echo -en '\e[1m' >&3
    echo -n "$1 [$2]" >&3
    echo -en '\e[0m ' >&3
    read -u 3 VALUE
    if [ -z "$VALUE" ]; then
      VALUE=$2
    fi
    echo "$VALUE"
  }

  prompt-numeric() {
    local NUMERIC_REGEX="^[0-9]+$"
    while true; do
      local VALUE=$(prompt "$@")

      if ! [[ "$VALUE" =~ $NUMERIC_REGEX ]] ; then
        echo "You entered '$VALUE'. Please enter a number." >&3
      else
        echo "$VALUE"
        return
      fi
    done
  }

  prompt-yesno() {
    while true; do
      local VALUE=$(prompt "$@")

      case $VALUE in
        y | Y | yes | YES | Yes )
          return 0
          ;;
        n | N | no | NO | No )
          return 1
          ;;
      esac

      echo "*** Please answer \"yes\" or \"no\"."
    done
  }

  # Define global variables that the install script will use to mark its
  # own progress.
  USE_DEFAULTS="no"
  WORK_DIR="${WORK_DIR:-$(mktemp -d ./lukava-icinga-plugins-installer.XXXXXXXXXX)}"
  DEFAULT_PLUGIN_DIR="/usr/lib64/nagios/plugins"
  INSTALL_AWS_WORKSPACE_PLUGINS="no"
  NODE_VERSION="v12.18.4"
  CURRENTLY_UID_ZERO="no"
  PREFER_ROOT="yes"

  detect_current_uid() {
    if [ $(id -u) = 0 ]; then
      CURRENTLY_UID_ZERO="yes"
    fi
  }

  handle_args() {
    SCRIPT_NAME=$1
    shift

    # Keep a copy of the ORIGINAL_ARGS so that, when re-execing ourself,
    # we can pass them in.
    ORIGINAL_ARGS=("$@")

    # Pass positional parameters through
    shift "$((OPTIND - 1))"
  }

  rerun_script_as_root() {
    # Note: This function assumes that the caller has requested
    # permission to use sudo!

    # Pass $@ here to enable the caller to provide environment
    # variables to bash, which will affect the execution plan of
    # the resulting install script run.

    # Remove newlines in $@, otherwise when we try to use $@ in a string passed
    # to 'bash -c' the command gets cut off at the newline. ($@ contains newlines
    # because at the call site we used escaped newlines for readability.)
    local ENVVARS=$(echo $@)

    # Add CURL_USER_AGENT to ENVVARS, since we always need to pass this
    # through.
    ENVVARS="$ENVVARS CURL_USER_AGENT=$CURL_USER_AGENT WORK_DIR=$WORK_DIR"

    if [ "$(basename $SCRIPT_NAME)" == bash ]; then
      # Probably ran like "curl -s https://raw.githubusercontent.com/lukavalabs/nagios-plugins/master/install.sh | bash"
      echo "Re-running script as root..."

      exec sudo bash -euo pipefail -c "curl -fs -A $CURL_USER_AGENT https://raw.githubusercontent.com/lukavalabs/nagios-plugins/master/install.sh | $ENVVARS bash"
    elif [ "$(basename $SCRIPT_NAME)" == install.sh ] && [ -e "$0" ]; then
      # Probably ran like "bash install.sh" or "./install.sh".
      echo "Re-running script as root..."
      if [ ${#ORIGINAL_ARGS[@]} = 0 ]; then
        exec sudo $ENVVARS bash "$SCRIPT_NAME"
      else
        exec sudo $ENVVARS bash "$SCRIPT_NAME" "${ORIGINAL_ARGS[@]}"
      fi
    fi

    # Don't know how to run the script. Let the user figure it out.
    REPORT=no fail "E_CANT_SWITCH_TO_ROOT" "ERROR: This script could not detect its own filename, so could not switch to root. \
Please download a copy and name it 'install.sh' and run that as root, perhaps using sudo."
  }

  assert_on_terminal() {
    if [ "no" = "$USE_DEFAULTS" ] && [ ! -t 1 ]; then
      REPORT=no fail "E_NO_TTY" "This script is interactive. Please run it on a terminal."
    fi

    # Hack: If the script is being read in from a pipe, then FD 0 is not the terminal input. But we
    #   need input from the user! We just verified that FD 1 is a terminal, therefore we expect that
    #   we can actually read from it instead. However, "read -u 1" in a script results in
    #   "Bad file descriptor", even though it clearly isn't bad (weirdly, in an interactive shell,
    #   "read -u 1" works fine). So, we clone FD 1 to FD 3 and then use that -- bash seems OK with
    #   this.
    exec 3<&1
  }

  plugin_prompts() {
    if prompt-yesno "Install AWS Workspace Plugins?" "yes"; then
      INSTALL_AWS_WORKSPACE_PLUGINS="yes"
      verify_node
    fi
  }

  verify_node() {
    if test -z "$(type -p node)"; then
      local NODE_DIR="/usr/local/lib/nodejs"
      echo "AWS Plugins require NodeJS."
      if prompt-yesno "Install NodeJS $NODE_VERSION now?" "yes"; then
        echo "Downloading: NodeJS $NODE_VERSION"
        retryable_curl "https://nodejs.org/download/release/$NODE_VERSION/node-$NODE_VERSION-linux-x64.tar.xz" "$WORK_DIR/node-$NODE_VERSION-linux-x64.tar.xz"

        echo "Unpacking: NodeJS $NODE_VERSION"
        mkdir -p $NODE_DIR
        tar -xJf "$WORK_DIR/node-$NODE_VERSION-linux-x64.tar.xz" -C $NODE_DIR
        ln -s $NODE_DIR/node-$NODE_VERSION-linux-x64/bin/node /usr/bin/node
        echo "NodeJS $NODE_VERSION Installed"
      fi
    fi
  }

  do_check_ndrestart() {
    echo "Downloading: check_ndrestart.sh"
    retryable_curl "https://raw.githubusercontent.com/Tontonitch/check_ndrestart/master/check_ndrestart.sh" "$WORK_DIR/check_ndrestart"

    echo "Downloading: check_ndrestart.patch"
    retryable_curl "https://raw.githubusercontent.com/lukavalabs/nagios-plugins/master/check_ndrestart.patch" "$WORK_DIR/check_ndrestart.patch"
    do_patch
    do_sudoers
  }

  do_patch() {
    echo "Patching..."
    patch -d "$WORK_DIR" < $WORK_DIR/*.patch >&2
  }

  do_sudoers() {
    local SUDOERS=/etc/sudoers.d/check_ndrestart
    if [ ! -f "$SUDOERS" ]; then
      cat >$SUDOERS <<EOL
Defaults:icinga   !requiretty
icinga ALL=(root) NOPASSWD: /usr/bin/needs-restarting
EOL
      chmod 440 $SUDOERS
    fi
  }

  do_check_aws_workspace() {
    if [ "yes" == "$INSTALL_AWS_WORKSPACE_PLUGINS" ]; then
      echo "Downloading: check_aws_workspaces_connected.js"
      retryable_curl "https://raw.githubusercontent.com/lukavalabs/nagios-plugins/v0.1/check_aws_workspaces_connected.js" "$WORK_DIR/check_aws_workspaces_connected"

      echo "Downloading: check_aws_workspaces_health.js"
      retryable_curl "https://raw.githubusercontent.com/lukavalabs/nagios-plugins/master/check_aws_workspaces_health.js" "$WORK_DIR/check_aws_workspaces_health"
    fi
  }

  do_plugins_install() {
    echo "Installing Plugins..."
    chmod +x $WORK_DIR/check_*
    cp "$WORK_DIR/check_ndrestart" "$DEFAULT_PLUGIN_DIR/check_ndrestart"
    if [ "yes" == "$INSTALL_AWS_WORKSPACE_PLUGINS" ]; then
      cp "$WORK_DIR/check_aws_workspaces_health" "$DEFAULT_PLUGIN_DIR/check_aws_workspaces_health"
      cp "$WORK_DIR/check_aws_workspaces_connected" "$DEFAULT_PLUGIN_DIR/check_aws_workspaces_connected"
    fi
  }

  cleanup(){
    rm -rf "$WORK_DIR"
  }

  handle_args "$@"
  assert_on_terminal
  detect_current_uid
  if [ "yes" != "$CURRENTLY_UID_ZERO" ]; then
    rerun_script_as_root
  fi
  plugin_prompts
  do_check_ndrestart
  do_check_aws_workspace
  do_plugins_install
  cleanup
  echo "Installation completed."
}

# Now that we know the whole script has downloaded, run it.
_ "$0" "$@"
