const TURSO_URL = process.env.TURSO_DB_URL?.replace("libsql://", "https://") + "/v2/pipeline";
const TURSO_TOKEN = process.env.TURSO_DB_TOKEN;

function error(res, code, msg) {
  res.status(code).json({ error: msg });
}

function turso(sql, args) {
  const body = JSON.stringify({
    requests: [{ type: "execute", stmt: { sql, args: args || [] } }],
  });
  return fetch(TURSO_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${TURSO_TOKEN}`,
      "Content-Type": "application/json",
    },
    body,
  }).then((r) => r.json());
}

export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");

  if (req.method === "OPTIONS") return res.status(204).end();

  if (req.method === "GET") {
    const since = parseInt(req.query.since) || 0;
    const limit = parseInt(req.query.limit) || 50;
    const result = await turso(
      "SELECT id, sender, subject, body, ts FROM messages WHERE id > ? ORDER BY id DESC LIMIT ?",
      [
        { type: "integer", value: String(since) },
        { type: "integer", value: String(limit) },
      ],
    );
    const rows = result.results?.[0]?.response?.result?.rows || [];
    const messages = rows.map((r) => ({
      id: parseInt(r[0].value),
      sender: r[1].value,
      subject: r[2].value,
      body: r[3].value,
      ts: r[4].value,
    }));
    return res.json({ messages, total: messages.length });
  }

  if (req.method === "POST") {
    const { sender, subject, body } = req.body || {};
    if (!subject && !body) return error(res, 400, "subject or body required");
    const result = await turso(
      "INSERT INTO messages (sender, subject, body) VALUES (?, ?, ?)",
      [
        { type: "text", value: sender || "unknown" },
        { type: "text", value: subject || "" },
        { type: "text", value: body || "" },
      ],
    );
    const id = result.results?.[0]?.response?.result?.last_insert_rowid;
    return res.json({ status: "ok", id: id ? parseInt(id) : null });
  }

  return error(res, 405, "method not allowed");
}