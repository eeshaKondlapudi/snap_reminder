import http from "node:http";
import { existsSync, readFileSync } from "node:fs";

loadEnvFile();

const port = Number(process.env.PORT || 8787);
const host = process.env.HOST || "127.0.0.1";
const model = process.env.GEMINI_MODEL || "gemini-2.5-flash";
const apiKey = process.env.GEMINI_API_KEY;
const requestTimeoutMs = Number(process.env.GEMINI_TIMEOUT_MS || 30000);

if (!apiKey) {
  console.warn("GEMINI_API_KEY is not set. Add it to .env or export it before starting the server.");
}

const server = http.createServer(async (request, response) => {
  response.setHeader("Access-Control-Allow-Origin", "*");
  response.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  response.setHeader("Access-Control-Allow-Headers", "Content-Type");

  if (request.method === "OPTIONS") {
    response.writeHead(204);
    response.end();
    return;
  }

  if (request.method !== "POST" || request.url !== "/ai-scan") {
    writeJson(response, 404, { error: "Not found" });
    return;
  }

  try {
    const body = await readJson(request);
    const imageBase64 = body.imageBase64;
    if (!imageBase64 || typeof imageBase64 !== "string") {
      writeJson(response, 400, { error: "imageBase64 is required" });
      return;
    }

    console.log(`AI scan request received: ${Math.round(imageBase64.length / 1024)}KB image, model=${model}`);
    const result = await analyzeScreenshot(imageBase64);
    console.log(`AI scan completed: ${result.meetings.length} meeting(s)`);
    writeJson(response, 200, result);
  } catch (error) {
    console.error("AI scan failed:", error);
    writeJson(response, 500, {
      error: error instanceof Error ? error.message : String(error),
    });
  }
});

server.listen(port, host, () => {
  console.log(`Gemini AI scan server listening on http://${host}:${port}`);
});

async function analyzeScreenshot(imageBase64) {
  if (!apiKey) {
    throw new Error("Missing GEMINI_API_KEY");
  }

  const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), requestTimeoutMs);
  let geminiResponse;
  try {
    geminiResponse = await fetch(endpoint, {
      method: "POST",
      signal: controller.signal,
      headers: {
        "x-goog-api-key": apiKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        contents: [
          {
            role: "user",
            parts: [
              {
                inline_data: {
                  mime_type: "image/jpeg",
                  data: imageBase64,
                },
              },
              { text: promptText() },
            ],
          },
        ],
        generationConfig: {
          temperature: 0,
          responseMimeType: "application/json",
          responseJsonSchema: responseSchema(),
        },
      }),
    });
  } catch (error) {
    if (error?.name === "AbortError") {
      throw new Error(`Gemini request timed out after ${requestTimeoutMs / 1000}s`);
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }

  const raw = await geminiResponse.text();
  if (!geminiResponse.ok) {
    throw new Error(`Gemini error ${geminiResponse.status}: ${raw}`);
  }

  const data = JSON.parse(raw);
  const content = data.candidates?.[0]?.content?.parts
    ?.map((part) => part.text || "")
    .join("")
    .trim();
  if (!content) {
    throw new Error("Gemini returned no text content");
  }

  const parsed = JSON.parse(content);
  if (!Array.isArray(parsed.meetings)) {
    return { meetings: [] };
  }
  return {
    meetings: parsed.meetings.map(normalizeMeeting).filter(Boolean),
  };
}

function promptText() {
  return [
    "You are reading an Outlook week-calendar screenshot.",
    "Find every visible meeting or class block in the calendar grid.",
    "Do not require red marks, highlights, stars, or any other user markings.",
    "Ignore calendar chrome, empty time slots, headers, dates, and time labels unless they help infer a meeting time.",
    "Infer dates and start/end times from the visible calendar grid.",
    "Use 24-hour times.",
    "If unsure, still give the best estimate and lower confidence.",
    "Return only the requested JSON object.",
  ].join(" ");
}

function responseSchema() {
  return {
    type: "object",
    properties: {
      meetings: {
        type: "array",
        items: {
          type: "object",
          properties: {
            title: { type: "string" },
            date: { type: "string" },
            start_time: { type: "string" },
            end_time: {
              anyOf: [{ type: "string" }, { type: "null" }],
            },
            reason: { type: "string" },
            confidence: { type: "number" },
          },
          required: [
            "title",
            "date",
            "start_time",
            "reason",
            "confidence",
          ],
        },
      },
    },
    required: ["meetings"],
  };
}

function normalizeMeeting(meeting) {
  if (!meeting || typeof meeting !== "object") {
    return null;
  }
  return {
    title: String(meeting.title || "Untitled meeting"),
    date: String(meeting.date || ""),
    start_time: String(meeting.start_time || ""),
    end_time: meeting.end_time == null ? null : String(meeting.end_time),
    reason: String(meeting.reason || "Detected from the calendar screenshot"),
    confidence: clamp(Number(meeting.confidence || 0.7), 0.1, 0.98),
  };
}

function clamp(value, min, max) {
  if (Number.isNaN(value)) {
    return min;
  }
  return Math.min(max, Math.max(min, value));
}

function readJson(request) {
  return new Promise((resolve, reject) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      body += chunk;
      if (body.length > 7_000_000) {
        reject(new Error("Request body too large"));
        request.destroy();
      }
    });
    request.on("end", () => {
      try {
        resolve(JSON.parse(body || "{}"));
      } catch (error) {
        reject(error);
      }
    });
    request.on("error", reject);
  });
}

function writeJson(response, status, value) {
  response.writeHead(status, { "Content-Type": "application/json" });
  response.end(JSON.stringify(value));
}

function loadEnvFile() {
  if (!existsSync(".env")) {
    return;
  }

  const lines = readFileSync(".env", "utf8").split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) {
      continue;
    }

    const separatorIndex = trimmed.indexOf("=");
    if (separatorIndex === -1) {
      continue;
    }

    const key = trimmed.slice(0, separatorIndex).trim();
    const rawValue = trimmed.slice(separatorIndex + 1).trim();
    if (!key || process.env[key] != null) {
      continue;
    }

    process.env[key] = stripOptionalQuotes(rawValue);
  }
}

function stripOptionalQuotes(value) {
  if (
    (value.startsWith('"') && value.endsWith('"')) ||
    (value.startsWith("'") && value.endsWith("'"))
  ) {
    return value.slice(1, -1);
  }
  return value;
}
