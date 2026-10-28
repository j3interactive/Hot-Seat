'use strict';
// Azure Web PubSub. Without WEBPUBSUB_CONNECTION_STRING it is a no-op and the
// browser falls back to polling, which keeps local development simple.
const HUB = process.env.WEBPUBSUB_HUB || 'seating';

function createRealtime() {
  const conn = process.env.WEBPUBSUB_CONNECTION_STRING;
  if (!conn) {
    return {
      enabled: false,
      async negotiate() { return null; },
      async publish() {}
    };
  }
  const { WebPubSubServiceClient } = require('@azure/web-pubsub');
  const client = new WebPubSubServiceClient(conn, HUB);
  return {
    enabled: true,
    async negotiate(user) {
      const token = await client.getClientAccessToken({ userId: user.upn, expirationTimeInMinutes: 60 });
      return token.url;
    },
    async publish(message) {
      try {
        await client.sendToAll(message);
      } catch (e) {
        // A failed push must never fail the write; clients resync on reconnect.
        console.error('Web PubSub publish failed:', e.message);
      }
    }
  };
}

module.exports = { createRealtime };
