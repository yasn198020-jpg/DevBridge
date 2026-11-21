import { chromium } from "playwright";
import readline from "node:readline";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const profile = path.resolve(root, "browser-profile");
const channel = process.env.DEVBRIDGE_BROWSER_CHANNEL || "msedge";
const chatUrl = process.env.DEVBRIDGE_CHAT_URL || "https://chatgpt.com/";

let context;
let page;

function output(value) {
  process.stdout.write(JSON.stringify(value) + "\n");
}

async function ensureBrowser() {
  if (context && page && !page.isClosed()) return;
  context = await chromium.launchPersistentContext(profile, {
    channel,
    headless: false,
    viewport: null,
    args: ["--start-maximized"]
  });
  const pages = context.pages();
  page = pages[0] || await context.newPage();
  if (!page.url().startsWith("https://chatgpt.com/")) {
    await page.goto(chatUrl, { waitUntil: "domcontentloaded" });
  }
}

async function lastAssistantMessage() {
  const messages = page.locator('[data-message-author-role="assistant"]');
  const count = await messages.count();
  if (count === 0) return "";
  return (await messages.nth(count - 1).innerText()).trim();
}

async function sendMessage(text) {
  const editors = page.locator('[contenteditable="true"]');
  const count = await editors.count();
  if (count === 0) throw new Error("ChatGPT message editor was not found.");
  const editor = editors.nth(count - 1);
  await editor.fill(text);
  await editor.press("Enter");
}

async function handle(command) {
  await ensureBrowser();
  switch (command.op) {
    case "snapshot":
      output({ ok: true, url: page.url(), assistantText: await lastAssistantMessage() });
      break;
    case "send":
      if (typeof command.text !== "string" || !command.text.trim()) {
        throw new Error("send requires non-empty text.");
      }
      await sendMessage(command.text);
      output({ ok: true });
      break;
    case "newchat":
      await page.goto(chatUrl, { waitUntil: "domcontentloaded" });
      output({ ok: true, url: page.url() });
      break;
    case "quit":
      output({ ok: true });
      await context.close();
      context = undefined;
      page = undefined;
      break;
    default:
      throw new Error("Unknown operation: " + command.op);
  }
}

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of rl) {
  if (!line.trim()) continue;
  try {
    await handle(JSON.parse(line));
  } catch (error) {
    output({ ok: false, error: String(error?.message || error) });
  }
}
