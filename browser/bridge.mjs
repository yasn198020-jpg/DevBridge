import { chromium } from "playwright";
import { readFileSync } from "node:fs";
import readline from "node:readline";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const settings = JSON.parse(readFileSync(path.join(root, "config/settings.json"), "utf8"));
const cdpUrl = process.env.DEVBRIDGE_CDP_URL || settings.browser?.cdpUrl || "http://127.0.0.1:9222";
const chatUrl = process.env.DEVBRIDGE_CHAT_URL || settings.browser?.chatUrl || "https://chatgpt.com/";
let savedChatUrl = null;
try {
  const state = JSON.parse(readFileSync(path.join(root, "state/monitor-state.json"), "utf8"));
  if (typeof state.lastChatUrl === "string") savedChatUrl = state.lastChatUrl;
} catch {}
let restoreAttempted = false;
let browser, context, page, preferredPage;
const output = value => process.stdout.write(JSON.stringify(value) + "\n");
const isChat = p => { try { return new URL(p.url()).origin === new URL(chatUrl).origin; } catch { return false; } };

async function choosePage() {
  const candidates = context.pages().filter(p => !p.isClosed() && isChat(p));
  if (!restoreAttempted) {
    restoreAttempted = true;
    const savedIsConversation = savedChatUrl && (() => {
      try { const u = new URL(savedChatUrl); return u.origin === new URL(chatUrl).origin && /\/c\/[0-9a-f-]+/i.test(u.pathname); }
      catch { return false; }
    })();
    if (savedIsConversation) {
      const savedPath = new URL(savedChatUrl).pathname.replace(/\/$/, "");
      const savedPage = candidates.find(p => {
        try { return new URL(p.url()).pathname.replace(/\/$/, "") === savedPath; }
        catch { return false; }
      });
      if (savedPage) {
        page = savedPage;
        preferredPage = savedPage;
        return savedPage;
      }
      // A different open conversation does not mean the saved last chat is restored.
      // Reuse an existing ChatGPT tab (or create one) and navigate it to the saved chat.
      const target = (preferredPage && !preferredPage.isClosed() && isChat(preferredPage))
        ? preferredPage
        : (candidates[0] || await context.newPage());
      await target.goto(savedChatUrl, { waitUntil: "domcontentloaded" });
      page = target; preferredPage = target;
      return target;
    }
  }
  for (const p of candidates) {
    const focused = await p.evaluate(() => document.visibilityState === "visible" && document.hasFocus()).catch(() => false);
    if (focused) { page = p; preferredPage = p; return p; }
  }
  if (preferredPage && !preferredPage.isClosed() && isChat(preferredPage)) page = preferredPage;
  else if (page && !page.isClosed() && isChat(page)) { /* retain last selected ChatGPT tab */ }
  else page = candidates[candidates.length - 1] || null;
  if (!page) { page = await context.newPage(); await page.goto(chatUrl, { waitUntil: "domcontentloaded" }); }
  preferredPage = page;
  return page;
}
async function ensureBrowser() {
  if (!browser || !context) {
    browser = await chromium.connectOverCDP(cdpUrl);
    context = browser.contexts()[0];
    if (!context) throw new Error("CDP connected, but browser has no accessible context.");
  }
}
const messages = target => target.locator('main [data-dil-response][data-dil-message-id]');
async function getSnapshot(target) {
  const list = messages(target), count = await list.count();
  let chars = 0;
  for (let i=0;i<count;i++) chars += (await list.nth(i).innerText()).length;
  const last = count ? list.nth(count-1) : null;
  const assistantText = last ? (await last.innerText()).trim() : "";
  const assistantMessageId = last ? await last.getAttribute("data-dil-message-id") : null;
  const match = target.url().match(/\/c\/([0-9a-f-]+)/i);
  return {ok:true,url:target.url(),conversationId:match?.[1]||null,assistantText,assistantMessageId,conversationCharacters:chars,conversationMessageCount:count};
}
async function send(target, text) {
  const editor0 = target.locator("#prompt-textarea").last();
  const editor = await editor0.count() ? editor0 : target.locator('[contenteditable="true"]').last();
  if (!(await editor.count())) throw new Error("ChatGPT composer not found; sign-in may be required.");
  await editor.fill(text);
  const button = target.locator('button[data-testid="send-button"]');
  if (await button.count() && await button.last().isEnabled()) await button.last().click();
  else await editor.press("Enter");
}
async function handle(cmd) {
  if (cmd.op === "quit") { output({ok:true,disconnected:true}); browser=undefined;context=undefined;page=undefined;preferredPage=undefined;return; }
  await ensureBrowser();
  if (cmd.op === "snapshot") {
    let target;
    if (cmd.conversationId) {
      target = context.pages().find(p => !p.isClosed() && isChat(p) && p.url().includes("/c/"+cmd.conversationId));
      if (!target) throw new Error("Requested conversation is no longer open.");
      page=target;preferredPage=target;
    } else if (cmd.pinPreferred && preferredPage && !preferredPage.isClosed()) target=preferredPage;
    else target=await choosePage();
    output(await getSnapshot(target)); return;
  }
  if (cmd.op === "send") {
    if (typeof cmd.text !== "string" || !cmd.text.trim()) throw new Error("send requires text.");
    let target;
    if (cmd.conversationId) {
      target = context.pages().find(p => !p.isClosed() && isChat(p) && p.url().includes("/c/"+cmd.conversationId));
      if (!target) throw new Error("Command conversation is no longer open; refusing to send to another chat.");
      page=target;preferredPage=target;
    } else if (cmd.pinPreferred && preferredPage && !preferredPage.isClosed()) target=preferredPage;
    else target=await choosePage();
    await send(target,cmd.text); output({ok:true,url:target.url()}); return;
  }
  if (cmd.op === "newchat") {
    let target;
    if (cmd.conversationId) {
      target = context.pages().find(p => !p.isClosed() && isChat(p) && p.url().includes("/c/"+cmd.conversationId));
      if (!target) throw new Error("Handoff conversation is no longer open.");
    } else target=await choosePage();
    await target.goto(chatUrl,{waitUntil:"domcontentloaded"});
    await target.waitForTimeout(1200);
    if (await messages(target).count()) throw new Error("ChatGPT did not open a blank conversation; refusing unsafe handoff.");
    page=target;preferredPage=target;output({ok:true,url:target.url()});return;
  }
  throw new Error("Unknown operation: "+cmd.op);
}
const rl=readline.createInterface({input:process.stdin,crlfDelay:Infinity});
for await (const line of rl) {
  if (!line.trim()) continue;
  try { await handle(JSON.parse(line.replace(/^\uFEFF/,""))); }
  catch(e) { output({ok:false,error:String(e?.message||e)}); }
}
