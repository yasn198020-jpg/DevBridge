import { chromium } from "playwright";
import readline from "node:readline";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
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
    channel, headless: false, viewport: null, args: ["--start-maximized"]
  });
  page = context.pages()[0] || await context.newPage();
  if (!page.url().startsWith("https://chatgpt.com/")) {
    await page.goto(chatUrl, { waitUntil: "domcontentloaded" });
  }
  await page.waitForTimeout(1500);
}
async function lastAssistantMessage() {
  const messages = page.locator('[data-message-author-role="assistant"]');
  const count = await messages.count();
  if (!count) return "";
  return (await messages.nth(count - 1).innerText()).trim();
}
async function sendMessage(text) {
  const editor = page.locator("#prompt-textarea").last();
  let activeEditor;
  if (await editor.count()) activeEditor = editor;
  else activeEditor = page.locator('[contenteditable="true"]').last();
  if (!(await activeEditor.count())) {
    throw new Error("ChatGPT composer not found; UI may have changed.");
  }
  await activeEditor.fill(text);
  const sendButton = page.locator('button[data-testid="send-button"]');
  if (await sendButton.count() && await sendButton.last().isEnabled()) {
    await sendButton.last().click();
  } else {
    await activeEditor.press("Enter");
  }
}
async function handle(command) {
  await ensureBrowser();
  switch (command.op) {
    case "snapshot":
      output({ ok: true, url: page.url(), assistantText: await lastAssistantMessage() });
      return;
    case "send":
      if (typeof command.text !== "string" || !command.text.trim()) {
        throw new Error("send requires text.");
      }
      await sendMessage(command.text);
      output({ ok: true });
      return;
    case "newchat":
      await page.goto(chatUrl, { waitUntil: "domcontentloaded" });
      output({ ok: true, url: page.url() });
      return;
    case "quit":
      output({ ok: true });
      await context.close();
      context = undefined;
      page = undefined;
      return;
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
