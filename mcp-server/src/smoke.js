import { resolve } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const transport = new StdioClientTransport({
  command: "node",
  args: [resolve("src/index.js")],
  env: {
    ...process.env,
    STUDIQUO_SNAPSHOT: resolve("test-fixture.json"),
    STUDIQUO_ACTIONS: resolve("test-actions.json")
  }
});

const client = new Client({ name: "studiquo-smoke", version: "0.1.0" });
await client.connect(transport);
const tools = await client.listTools();
if (tools.tools.length !== 6) throw new Error(`Expected 6 tools, got ${tools.tools.length}`);
const search = await client.callTool({ name: "search_notes", arguments: { query: "放物線" } });
if (search.isError) throw new Error("search_notes failed");
await client.close();
console.error("Studiquo MCP smoke test passed");
