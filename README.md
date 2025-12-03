# MacMailClauder

A macOS Mail.app integration for Claude Desktop via MCP (Model Context Protocol).

## Features

- **Search Emails** - Search by sender, subject, date range, or body content
- **Read Email Content** - Get full email content including body text
- **Search Attachments** - Search text content within PDFs, documents, etc.
- **Extract Attachments** - Get attachment content with text extraction
- **Open Emails** - Claude will open emails in Mail.app for you!
- **Configuration UI** - Menu bar app to control permissions and scope

## Some Things Explained

Please note this is in its early stages, however it works for me. I tried to build an integration another way, and at the point I realised I had almost basically built a whole email client and it was a bit overbearing I thought I should do it another way.

This integration is only for Apple Mail, and integrates with it via read-only usage of the SQLite databases and other files.

I discovered there are limitations on what you can easily/quickly get into Claude Desktop. This is particularly relevant for attachments and things. However, attachment data is passed to Claude Desktop as text to get around this.

This application has two components. A menu bar application for initial configuration, and a command line MCP server that runs from Claude. The MCP server inherits its permissions from Claude, which is why Claude needs Full Disk Access permissions. There are better ways to do this but this is how it is for now. Note that after initial configuration, you do not need to run the menu bar app unless you want to.

## Requirements

- macOS 26.0 (Tahoe)
- Claude Desktop
- Full Disk Access permission for Claude Desktop

## Installation

Please use one of the prepared signed package installers here from Github.

## Setup

### 1. Grant Full Disk Access

Claude Desktop needs Full Disk Access so when it runs our MCP server it runs can read Mail.app's database:

1. Open **System Settings** → **Privacy & Security** → **Full Disk Access**
2. Claude is probably already in the list. If it is, enable the switch.
2. If it is not, click the **+** button
3. Navigate to your applications folder, drag it in, and enable it.

### 2. Configure Claude Desktop

Click the menu bar icon and click **"Fix"** next to "Claude Desktop" - this automatically adds the MCP server to Claude's config.

Or manually add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "macmail": {
      "command": "/Applications/MacMailClauder.app/Contents/MacOS/MacMailClauderMCP"
    }
  }
}
```

### 3. Restart Claude Desktop

Restart Claude Desktop to load the MCP server.

## Usage

Once configured, you can ask Claude things like:

- "Search my emails for messages from Amazon"
- "Find emails about the project meeting last week"
- "Show me the PDF attachments I received this month"
- "Find the invoice with number 12345 in my attachments"
- "Open that email in Mail.app"

## License

MIT License
