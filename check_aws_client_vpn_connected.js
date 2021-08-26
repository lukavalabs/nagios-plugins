#!/usr/bin/node
const exec = require('child_process').execSync;

(function () {
  const region = JSON.parse(exec('curl -s http://169.254.169.254/latest/dynamic/instance-identity/document')).region;

  const endpointIds = JSON.parse(exec(`aws ec2 describe-client-vpn-endpoints --region ${region}`)
    .toString()).ClientVpnEndpoints.map(endpoint => endpoint.ClientVpnEndpointId);

  const connectedUsers = [];

  endpointIds.forEach(endpointId => {
    const connections = JSON.parse(
      exec(`aws ec2 describe-client-vpn-connections --client-vpn-endpoint-id ${endpointId} --region ${region}`)
        .toString()
    ).Connections;

    connections
      .filter(connection => connection.Status.Code === 'active')
      .forEach(connection => connectedUsers.push(connection.Username))
  });

  console.log(`Sessions: ${connectedUsers.length} - Users: ${connectedUsers.join(', ')}`);
  process.exit(0);
})();