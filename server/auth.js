'use strict';
// Reads the signed-in user from App Service authentication (Easy Auth).
// Easy Auth validates the Entra sign-in and forwards the claims in
// X-MS-CLIENT-PRINCIPAL; requests without it never reach the app in Azure.

const ROLE_RANK = { viewer: 0, supervisor: 1, admin: 2 };

function roleFromClaims(roles) {
  if (roles.includes('Seating.Admin')) return 'admin';
  if (roles.includes('Seating.Supervisor')) return 'supervisor';
  return 'viewer';
}

function userFromRequest(req) {
  const header = req.get('x-ms-client-principal');
  if (header) {
    try {
      const principal = JSON.parse(Buffer.from(header, 'base64').toString('utf8'));
      const claims = principal.claims || [];
      const get = (...types) => {
        const c = claims.find((x) => types.includes(x.typ));
        return c ? c.val : null;
      };
      const roleType = principal.role_typ || 'roles';
      const roles = claims.filter((c) => c.typ === roleType || c.typ === 'roles').map((c) => c.val);
      const upn = get('preferred_username', 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn') ||
        req.get('x-ms-client-principal-name') || 'unknown';
      return {
        name: get('name') || upn,
        upn,
        oid: get('http://schemas.microsoft.com/identity/claims/objectidentifier', 'oid'),
        role: roleFromClaims(roles)
      };
    } catch (e) {
      return null;
    }
  }
  // Local development only: never set DEV_USER in Azure.
  if (process.env.DEV_USER && !process.env.WEBSITE_SITE_NAME) {
    const role = ROLE_RANK[process.env.DEV_USER] !== undefined ? process.env.DEV_USER : 'viewer';
    const who = req.get('x-dev-user') || 'Local Dev';
    return { name: who, upn: who.toLowerCase().replace(/\s+/g, '.') + '@local', oid: null, role: req.get('x-dev-role') || role };
  }
  return null;
}

function requireUser(req, res, next) {
  const user = userFromRequest(req);
  if (!user) return res.status(401).json({ error: 'Not signed in' });
  req.user = user;
  next();
}

function atLeast(user, role) {
  return ROLE_RANK[user.role] >= ROLE_RANK[role];
}

module.exports = { requireUser, atLeast };
