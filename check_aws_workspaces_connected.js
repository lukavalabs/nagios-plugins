#!/usr/bin/node
const exec = require('child_process').execSync;

(function() {
  const region = JSON.parse(exec('curl -s http://169.254.169.254/latest/dynamic/instance-identity/document')).region;

  const statuses = JSON.parse(exec(`aws workspaces describe-workspaces-connection-status --region ${region}`)
    .toString()).WorkspacesConnectionStatus;

  const workspaces = JSON.parse(exec(`aws workspaces describe-workspaces --region ${region}`)
    .toString()).Workspaces;

  const connectedWorkspaces = statuses
    .filter(value => value.ConnectionState === 'CONNECTED')
    .map(value => value.WorkspaceId);

  const connectedUsers = workspaces
    .filter(value => connectedWorkspaces.includes(value.WorkspaceId))
    .map(value => value.UserName)
    .sort();

  console.log(`Sessions: ${connectedUsers.length} - Users: ${connectedUsers.join(', ')}`);
  process.exit(0);
})();