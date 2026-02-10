# Agentic Postgres Workshop - Pre-Workshop Setup Instructions

**Please complete these setup steps BEFORE attending the workshop.** The setup process takes approximately 15-20 minutes.

This workshop uses AI coding assistants to work with TigerData (TimescaleDB cloud service). You'll need to install and configure several tools before the workshop begins.

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Step 1: Access Your Command Line](#step-1-access-your-command-line)
4. [Step 2: Install Gemini CLI](#step-2-install-gemini-cli)
5. [Step 3: Authenticate Gemini CLI](#step-3-authenticate-gemini-cli)
6. [Step 4: Test Gemini CLI](#step-4-test-gemini-cli)
7. [Step 5: Install Tiger CLI](#step-5-install-tiger-cli)
8. [Step 6: Install psql (PostgreSQL Client)](#step-6-install-psql-postgresql-client)
9. [Step 7: Authenticate Tiger CLI](#step-7-authenticate-tiger-cli)
10. [Step 8: Connect Tiger MCP to Gemini CLI](#step-8-connect-tiger-mcp-to-gemini-cli)
11. [Step 9: Test the Integration](#step-9-test-the-integration)
12. [Step 10: Download Workshop Materials](#step-10-download-workshop-materials)
13. [Troubleshooting](#troubleshooting)
14. [Getting Help](#getting-help)

---

## Overview

**What you'll install:**
- **Gemini CLI** - A free AI coding assistant from Google
- **Tiger CLI** - A command-line tool for managing TigerData databases
- **psql** - PostgreSQL command-line client for direct database access
- **Git** (or curl/wget) - For downloading workshop materials

**What you'll need:**
- A Google account (for Gemini CLI - free tier is sufficient)
- A TigerData account (sign up at [console.tigerdata.com](https://console.tigerdata.com) - free tier available)
- Internet connection
- About 15-20 minutes

---

## Prerequisites

### Required Accounts

Before you begin, create these FREE accounts:

1. **Google Account** (for Gemini CLI)
   - If you don't have one, create it at [accounts.google.com](https://accounts.google.com)
   - The free tier is sufficient for this workshop

2. **TigerData Account** (for database services)
   - Sign up at [console.tigerdata.com](https://console.tigerdata.com)
   - Click "Sign up" and follow the registration process
   - The free tier includes enough resources for this workshop

---

## Step 1: Access Your Command Line

You'll need to use your computer's command line interface (terminal) for this setup.

### For macOS Users:

1. Press `Command (⌘) + Space` to open Spotlight Search
2. Type "Terminal" and press Enter
3. A terminal window will open - this is where you'll run all commands

### For Windows Users:

**Option A: Use PowerShell (Recommended)**
1. Press `Windows key + R`
2. Type "powershell" and press Enter
3. A blue terminal window will open

**Option B: Use Command Prompt**
1. Press `Windows key + R`
2. Type "cmd" and press Enter
3. A black terminal window will open

### For Linux Users:

1. Press `Ctrl + Alt + T` (on most distributions)
2. Or search for "Terminal" in your application menu

**Note:** Once you open your terminal, keep it open for all the following steps.

---

## Step 2: Install Gemini CLI

Gemini CLI is a free AI coding assistant from Google. It provides the AI capabilities we'll use to interact with databases during the workshop.

### Installation Instructions

**For macOS and Linux:**

Install globally with npm

```bash
npm install -g @google/gemini-cli
```

Install globally with Homebrew (macOS)

If brew is not installed - follow the ionstructions at https://brew.sh/

```bash
brew install gemini-cli
```

**Expected output:** You should see messages about downloading and installing Gemini CLI.

**For Windows (PowerShell):**

Run this command:

```powershell
iwr https://geminicli.com/install.ps1 -useb | iex
```

### Verify Installation

After installation completes, verify it worked by running:

```bash
gemini --version
```

**Expected output:** You should see a version number like `gemini version 1.x.x`

**If you get "command not found":**
- Close and reopen your terminal
- Try running the command again
- See [Troubleshooting](#troubleshooting) section below

---

## Step 3: Authenticate Gemini CLI

Now you need to connect Gemini CLI to your Google account.

### Authentication Steps

1. Run this command:

```bash
gemini auth login
```

2. **Expected behavior:**
   - Your web browser will automatically open
   - You'll be asked to sign in with your Google account
   - You'll see a permission request to allow Gemini CLI access
   - Click "Allow" or "Authorize"

3. **After authorizing:**
   - Return to your terminal
   - You should see a success message like "Authentication successful"

**If the browser doesn't open automatically:**
- The terminal will display a URL
- Copy the URL and paste it into your web browser manually
- Complete the authorization process
- Return to your terminal

---

## Step 4: Test Gemini CLI

Let's verify that Gemini CLI is working correctly.

### Test with a Simple Prompt

Run this command to start an interactive Gemini session:

```bash
gemini
```

**Expected behavior:**
- You'll see a prompt that says `You:` or similar
- The interface is ready for your input

Now type this simple test message:

```
Hello, please tell me what you can do
```

**Expected response:**
- Gemini should respond with information about its capabilities
- You should see a response within a few seconds

**To exit Gemini CLI:**
- Type `exit` or `quit`
- Or press `Ctrl + C` (on macOS/Linux) or `Ctrl + D` (on Windows)

**If this works, you're ready to move to the next step!**

---

## Step 5: Install Tiger CLI

Tiger CLI is a tool for managing TigerData database services. It also provides an MCP (Model Context Protocol) server that lets AI assistants interact with your databases.

### Installation Instructions

**For macOS, Linux, and Windows (Git Bash/WSL):**

Run this command in your terminal:

```bash
curl -fsSL https://cli.tigerdata.com | sh
```

**Expected output:** You'll see messages about downloading and installing Tiger CLI.

**For Windows (PowerShell):**

Run this command:

```powershell
iwr https://cli.tigerdata.com/install.ps1 -useb | iex
```

### Verify Installation

Check that Tiger CLI was installed correctly:

```bash
tiger version
```

**Expected output:** You should see a version number like `tiger version 1.x.x`

**If you get "command not found":**
- Close and reopen your terminal
- Try the command again
- Run: `echo 'export PATH="$HOME/bin:${PATH}"' >> ~/.zshrc`, then `source ~/.zshrc` and try again
- On Windows, you may need to restart PowerShell
- See [Troubleshooting](#troubleshooting) section

---

## Step 6: Install psql (PostgreSQL Client)

The `psql` command-line tool is the standard PostgreSQL interactive terminal. While not strictly required for the workshop (since we'll use Gemini CLI to interact with the database), having psql installed is useful for direct database queries and troubleshooting.

### Installation Instructions

**For macOS:**

If you have Homebrew installed:

```bash
brew install postgresql@17
```

After installation, add psql to your PATH:

```bash
echo 'export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

**For macOS without Homebrew:**

Download and install Postgres.app from [postgresapp.com](https://postgresapp.com):
1. Download Postgres.app
2. Move it to your Applications folder
3. Double-click to open
4. Click "Initialize" to create a new server
5. Add the command-line tools to your PATH:

```bash
sudo mkdir -p /etc/paths.d && echo /Applications/Postgres.app/Contents/Versions/latest/bin | sudo tee /etc/paths.d/postgresapp
```

**For Windows:**

Download the PostgreSQL installer from [postgresql.org](https://www.postgresql.org/download/windows/):

1. Visit the PostgreSQL download page
2. Download the installer for your version of Windows
3. Run the installer
4. During installation, you can uncheck "PostgreSQL Server" if you only need the client tools
5. Make sure "Command Line Tools" is checked
6. Complete the installation

**For Linux (Ubuntu/Debian):**

```bash
sudo apt update
sudo apt install postgresql-client
```

**For Linux (RedHat/CentOS/Fedora):**

```bash
sudo dnf install postgresql
```

### Verify Installation

Check that psql was installed correctly:

```bash
psql --version
```

**Expected output:** You should see a version number like `psql (PostgreSQL) 17.x` or `psql (PostgreSQL) 16.x`

**If you get "command not found":**
- On macOS: Make sure you added psql to your PATH (see above)
- On Windows: Restart your terminal or PowerShell
- On Linux: The package may be named differently; try `sudo apt install postgresql-client-common`

**Note:** You won't need to run a PostgreSQL server locally - we'll be connecting to TigerData cloud databases. We only need the `psql` client tool.

---

## Step 7: Authenticate Tiger CLI

Connect Tiger CLI to your TigerData account.

### Authentication Steps

1. Run this command:

```bash
tiger auth login
```

2. **Expected behavior:**
   - Your web browser will automatically open
   - You'll be directed to the TigerData login page
   - Sign in with the account you created at console.tigerdata.com

3. **After signing in:**
   - You may be asked to authorize Tiger CLI
   - Click "Authorize" or "Allow"
   - Return to your terminal
   - You should see "Authentication successful" or similar message

**If the browser doesn't open:**
- Look for a URL in your terminal output
- Copy and paste it into your browser manually
- Complete the login process
- Return to your terminal

### Verify Authentication

Check that you're properly authenticated:

```bash
tiger service list
```

**Expected output:**
- If you have no services yet: "No services found" (this is normal)
- If you have services: A list of your database services
- Either output means authentication worked!

---

## Step 8: Connect Tiger MCP to Gemini CLI

Now we'll connect the Tiger MCP server to Gemini CLI, allowing the AI assistant to interact with TigerData.

### Install Tiger MCP Integration

Run this command:

```bash
tiger mcp install
```

**Expected behavior:**
- The installer will detect Gemini CLI
- It will automatically configure the integration
- You'll see confirmation messages about the installation

**You should see:**
- "Detected Gemini CLI"
- "Installing Tiger MCP server..."
- "Installation successful" or similar

**Note:** If you have multiple AI assistants installed (like Cursor or VS Code), the installer may ask which one to configure. Select Gemini CLI from the list.

---

## Step 9: Test the Integration

Now let's verify that Gemini CLI can communicate with TigerData through the Tiger MCP server.

### Test the Integration

1. Start Gemini CLI:

```bash
gemini
```

2. Once you see the `You:` prompt, type this EXACT prompt:

```
what tools do you have access to?
```

**Expected response:**
- Gemini should list various tools including Tiger-related functions
- Look for tools like:
  - `tiger__service_list`
  - `tiger__service_create`
  - `tiger__db_execute_query`
  - `tiger__search_docs`
  - And others with `tiger__` prefix

3. Now test the connection by asking Gemini to list your services:

```
list my tigerdata services
```

**Expected response:**
- Gemini will use the Tiger MCP tools to query your account
- You'll see either:
  - "You have no services" (if you haven't created any yet - this is fine!)
  - Or a list of your existing services
- This confirms the integration is working!

4. Exit Gemini CLI:
   - Type `exit` or press `Ctrl + C`

**If you see the Tiger tools and can successfully list services, you're all set!**

---

## Step 10: Download Workshop Materials

The workshop uses sample CSV files with time-series sensor data. You need to download these files to your computer.

### Option A: Clone the Repository (Recommended if you have Git)

**Check if you have Git installed:**

```bash
git --version
```

If you see a version number, you have Git. If not, see "Option B" below.

**Clone the repository:**

```bash
git clone https://github.com/timescale/TigerData-Workshops.git
```

**Navigate to the workshop directory:**

```bash
cd TigerData-Workshops/Agentic-Postgres-Workshop
```

**Verify the files are there:**

```bash
ls
```

You should see files including `data.csv` and `sensors.csv`.

### Option B: Download Files Manually (If you don't have Git)

**For macOS and Linux (using curl):**

Create a directory for the workshop:

```bash
mkdir -p ~/agentic-postgres-workshop
cd ~/agentic-postgres-workshop
```

Download the CSV files:

```bash
curl -O https://raw.githubusercontent.com/timescale/TigerData-Workshops/main/Agentic-Postgres-Workshop/data.csv

curl -O https://raw.githubusercontent.com/timescale/TigerData-Workshops/main/Agentic-Postgres-Workshop/sensors.csv
```

**For Windows (using PowerShell):**

Create a directory:

```powershell
mkdir $HOME\agentic-postgres-workshop
cd $HOME\agentic-postgres-workshop
```

Download the CSV files:

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/timescale/TigerData-Workshops/main/Agentic-Postgres-Workshop/data.csv" -OutFile "data.csv"

Invoke-WebRequest -Uri "https://raw.githubusercontent.com/timescale/TigerData-Workshops/main/Agentic-Postgres-Workshop/sensors.csv" -OutFile "sensors.csv"
```

### Option C: Download via Web Browser

1. Visit: [https://github.com/timescale/TigerData-Workshops/tree/main/Agentic-Postgres-Workshop](https://github.com/timescale/TigerData-Workshops/tree/main/Agentic-Postgres-Workshop)
2. Click on `data.csv`, then click "Download" or "Raw" button
3. Save the file to a folder on your computer (e.g., `Documents/agentic-postgres-workshop`)
4. Repeat for `sensors.csv`
5. Remember the folder location - you'll need it during the workshop!

### Verify Your Files

Check that you have both files:

**macOS/Linux:**
```bash
ls -lh *.csv
```

**Windows:**
```powershell
dir *.csv
```

**Expected output:**
- You should see two files: `data.csv` and `sensors.csv`
- `data.csv` should be several MB in size
- `sensors.csv` should be much smaller (a few KB)

---

## Troubleshooting

### Problem: "Command not found" errors

**Solution:**
1. Close your terminal completely
2. Open a new terminal window
3. Try the command again

**If still not working:**
- The installation may have succeeded but your terminal needs to reload its PATH
- On macOS/Linux: Run `source ~/.bashrc` or `source ~/.zshrc`
- On Windows: Restart PowerShell

### Problem: Gemini CLI browser authentication not working

**Solution:**
1. Look for a URL in the terminal output
2. Copy the entire URL
3. Paste it manually into your web browser
4. Complete the authorization
5. You may see a code - copy it and paste it back into your terminal

### Problem: Tiger CLI authentication fails

**Solution:**
1. Make sure you've created an account at [console.tigerdata.com](https://console.tigerdata.com)
2. Try running `tiger auth login` again
3. If the browser doesn't open, look for a URL in the terminal and open it manually
4. Clear your browser cache and try again

### Problem: Gemini CLI doesn't show Tiger tools

**Solution:**
1. Make sure Tiger CLI is installed: `tiger version`
2. Reinstall the MCP integration: `tiger mcp install`
3. Completely quit and restart Gemini CLI
4. Try asking "what tools do you have access to?" again

### Problem: Cannot download CSV files

**Solution:**
- Check your internet connection
- Try the alternative download method (web browser)
- Visit the GitHub repository directly and download files manually
- Make sure you're using the correct URLs

### Problem: Git not installed (when trying Option A)

**Solution:**
- Use Option B (curl/PowerShell) or Option C (web browser) instead
- Or install Git:
  - macOS: Run `xcode-select --install`
  - Windows: Download from [git-scm.com](https://git-scm.com)
  - Linux: Run `sudo apt install git` (Ubuntu/Debian) or `sudo yum install git` (RedHat/CentOS)

---

## Getting Help

If you encounter issues during setup:

1. **Review the Troubleshooting section above**
2. **Check your terminal output** - error messages often contain helpful information
3. **Verify each step** - go back through the instructions to make sure you didn't skip anything
4. **Documentation resources:**
   - Gemini CLI: [geminicli.com](https://geminicli.com)
   - Tiger CLI: [github.com/timescale/tiger-cli](https://github.com/timescale/tiger-cli)
   - TigerData: [console.tigerdata.com](https://console.tigerdata.com)

5. **Contact the workshop organizer** if you're still stuck - bring your error messages and we'll help you resolve issues before the workshop begins

---

## Pre-Workshop Checklist

Before attending the workshop, verify you can do the following:

- [ ] Open a terminal on your computer
- [ ] Run `gemini --version` and see a version number
- [ ] Run `tiger version` and see a version number
- [ ] Run `psql --version` and see a version number
- [ ] Run `gemini` and interact with the AI assistant
- [ ] Ask Gemini "what tools do you have access to?" and see Tiger tools listed
- [ ] Ask Gemini "list my tigerdata services" and get a response (even if empty)
- [ ] Have `data.csv` and `sensors.csv` files downloaded and accessible
- [ ] Know the location of your workshop files folder

**If you can check all these boxes, you're ready for the workshop!**

---

## Workshop Resources

- **Workshop GitHub Repository:** [github.com/timescale/TigerData-Workshops](https://github.com/timescale/TigerData-Workshops)
- **Specific Workshop Directory:** [Agentic-Postgres-Workshop](https://github.com/timescale/TigerData-Workshops/tree/main/Agentic-Postgres-Workshop)
- **TigerData Console:** [console.tigerdata.com](https://console.tigerdata.com)

---

**See you at the workshop!**