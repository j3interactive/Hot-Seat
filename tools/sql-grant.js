'use strict';
// Grants the App Service managed identity access to the database.
// Run by infra/deploy.sh with the deploying user's Entra token (the SQL admin):
//   SQL_TOKEN=... node tools/sql-grant.js <server-fqdn> <database> <identity-name> <identity-client-id>
// Uses CREATE USER ... WITH SID so the SQL server needs no Microsoft Graph permissions.
const sql = require('mssql');

async function main() {
  const [server, database, name, clientId] = process.argv.slice(2);
  const token = process.env.SQL_TOKEN;
  const guid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (!server || !database || !/^[A-Za-z0-9-]+$/.test(name || '') || !guid.test(clientId || '') || !token) {
    console.error('usage: SQL_TOKEN=... node tools/sql-grant.js <server> <db> <identity-name> <client-id>');
    process.exit(2);
  }
  const pool = await new sql.ConnectionPool({
    server, database,
    options: { encrypt: true },
    authentication: { type: 'azure-active-directory-access-token', options: { token } }
  }).connect();
  await pool.request().batch(`
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'${name}')
  CREATE USER [${name}] WITH SID = ${'0x' + Buffer.from(guidBytes(clientId)).toString('hex')}, TYPE = E;
ALTER ROLE db_datareader ADD MEMBER [${name}];
ALTER ROLE db_datawriter ADD MEMBER [${name}];
ALTER ROLE db_ddladmin ADD MEMBER [${name}];`);
  console.log(`Granted ${name} read, write and schema rights on ${database}`);
  await pool.close();
}

// SQL stores a uniqueidentifier with the first three groups little-endian.
function guidBytes(g) {
  const hex = g.replace(/-/g, '');
  const b = Buffer.from(hex, 'hex');
  const swap = (s, e) => b.subarray(s, e).reverse();
  return Buffer.concat([swap(0, 4), swap(4, 6), swap(6, 8), b.subarray(8)]);
}

main().catch((e) => { console.error('SQL grant failed:', e.message); process.exit(1); });
