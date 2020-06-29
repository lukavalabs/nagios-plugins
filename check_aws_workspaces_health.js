#!/usr/bin/node
const exec = require('child_process').execSync;

(function() {
  const region = JSON.parse(exec('curl -s http://169.254.169.254/latest/dynamic/instance-identity/document')).region;

  const workspaces = JSON.parse(exec(`aws workspaces describe-workspaces --region ${region}`)
    .toString()).Workspaces;

  const exclusions = ['AVAILABLE', 'STARTING', 'STOPPED'];

  const unhealthyWorkspaces = workspaces
    .filter(value => exclusions.indexOf(value.State) < 0)
    .map(value => { return { name: value.UserName, status: value.State } });

  if (unhealthyWorkspaces.length > 0) {
    const critical = unhealthyWorkspaces.reduce((prev, next, index) => {
      if (index === 0) {
        return `${next.name} (${next.status})`;
      }
      return `${prev}, ${next.name} (${next.status})`;
    }, '');
    console.log(`CRITICAL: ${critical}`);
    process.exit(2);
  }

  console.log('OK: All Healthy');
  process.exit(0);
})();