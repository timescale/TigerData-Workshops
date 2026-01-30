# Agentic Postgres Workshop

This workshop demonstrates how to work with TigerData using Tiger MCP tools and AI coding assistants. You'll learn how to leverage AI agents to create optimized database schemas, analyze time-series data, and perform database optimization tasks.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Setup](#setup)
  - [Install Tiger CLI](#install-tiger-cli)
  - [Authenticate with Tiger Cloud](#authenticate-with-tiger-cloud)
  - [Connect Tiger MCP to Your AI Assistant](#connect-tiger-mcp-to-your-ai-assistant)
  - [Test the Integration](#test-the-integration)
- [Workshop Exercises](#workshop-exercises)
  - [1. Generate Sample Data (Optional)](#1-generate-sample-data-optional)
  - [2. Create Database and Schema](#2-create-database-and-schema)
  - [3. Data Analysis](#3-data-analysis)
  - [4. Performance Analysis](#4-performance-analysis)
  - [5. Data Retention Experiment](#5-data-retention-experiment)
  - [6. Database Optimization](#6-database-optimization)
- [Additional Resources](#additional-resources)

## Prerequisites

- A Tiger Cloud account (sign up at [https://tigerdata.com](https://tigerdata.com))
- An AI coding assistant tool (see supported tools below)
- Python 3.x (optional, for data generation)

## Setup

### Install Tiger CLI

Tiger CLI is an open-source command-line tool and MCP (Model Context Protocol) server for managing and querying database services. It provides AI assistance tools like Claude Code with access to PostgreSQL and TigerData/TimescaleDB best practices.

**Source code and documentation:** [https://github.com/timescale/tiger-cli](https://github.com/timescale/tiger-cli)

Install Tiger CLI by running:

```bash
curl -fsSL https://cli.tigerdata.com | sh
```

Verify the installation:

```bash
tiger version
```

### Authenticate with Tiger Cloud

After installing Tiger CLI, authenticate with your Tiger Cloud account:

```bash
tiger auth login
```

This will open a browser window to complete the authentication process.

### Connect Tiger MCP to Your AI Assistant

Tiger CLI supports integration with various AI coding assistant tools:

- **Claude Code** (recommended for this workshop)
- Codeium
- Cursor
- Gemini CLI
- Google Antigravity
- Kiro CLI
- VS Code with Copilot
- Windsurf

**Note:** Most tools require a paid subscription to services such as Anthropic or OpenAI. If you don't have a paid subscription, you can use [Gemini CLI](https://geminicli.com/), which includes a generous free tier sufficient to complete this workshop.

To install the Tiger MCP server for your AI assistant:

```bash
tiger mcp install
```

The installer will detect your available tools and configure them automatically. If your tool is not listed, you may still be able to use it if it supports MCP via stdio or HTTP. Refer to your tool's documentation and the [TigerCLI documentation](https://github.com/timescale/tiger-cli) for manual integration instructions.

### Test the Integration

Verify that your AI assistant has access to Tiger MCP tools. For example, if using Gemini CLI:

```bash
gemini
```

Then ask:

```text
what tools do you have access to?
```

The response should include tools like:
- `semantic-search-tiger-docs`
- `service-list`
- `service-fork`
- `db-execute-query`
- And other Tiger-related functions

## Workshop Exercises

### 1. Generate Sample Data (Optional)

Github repo already includes `data.csv` and `sensors.csv` files. You can use these and skip this section. Note: the data might be from the older time range.

The repository includes a Python script to generate sample time-series sensor data. This script was created by Claude Code using AI-assisted development.

**Original prompt used to create the script:**

```text
generate python script that would create csv files with timeseries data:
*data.csv:*
- Row format: `timestamp, sensor_id, temperature, humidity`
- 20 sensors
- Each sensor emits data every minute
- 2 months of data
- Data should reflect daily and weekly patterns

*sensors.csv:*
- Row format: `sensor_id, model, location`
- Contains metadata for each sensor
- Locations: room 1, room 2, etc.
```

Run the script:

```bash
python generate_sensor_data.py
```

This will create `data.csv` and `sensors.csv` files. Alternatively, you can use your own dataset.

### 2. Create Database and Schema

Use your AI coding assistant to create an optimized database schema using TigerData best practices.

**Prompt for your AI assistant to design the schema:**

```text
- Examine two CSV files in this directory
- Use Tiger MCP for best practices and documentation and create an optimized schema for the data
- Save the schema to `schema.sql`
```

After schema is created, examine it and if you are satisfied with the result continue to service creation:

**Prompt for your AI assistant to create Tiger Serivce, apply schema and load the data:**

```text
- Create Tiger service `agentic-postgres-workshop` if not already created
- Apply schema to the newly created database
- Load data from CSV files
```

**What to expect:**
- The AI will analyze your CSV files
- Design an optimized schema with hypertables for time-series data
- Create appropriate indexes and continuous aggregates
- Create a TigerData service (TimescaleDB instance)
- Appl schema and load your data into the database

### 3. Data Analysis

AI coding agents excel at constructing complex SQL queries for data analysis. Let's explore the database and identify patterns in the data.

**Prompt:**

```text
- Query and document tables, hypertables and continuous aggregates in the database

- Count and analyze the volume of data in the sensor readings

- Scan the sensor data for outliers. Explain why each identified data point is considered an anomaly based on its deviation from the typical pattern
```

**What to expect:**
- A comprehensive overview of your database structure
- Statistics about data volume and distribution
- Identification of anomalous readings with explanations

### 4. Performance Analysis

Compare query performance with and without TimescaleDB's continuous aggregates feature.

**Prompt:**

```text
- Compare query performance with and without continuous aggregate
```

**What to expect:**
- The AI will run benchmark queries
- Compare execution times and resource usage
- Demonstrate the performance benefits of continuous aggregates for time-series data

### 5. Data Retention Experiment

Experiment with data retention policies using database forking to safely test without affecting your original data.

**Prompt:**

```text
- Consult with Tiger MCP for query syntax details as you go
- Create a fork of the database and continue on the fork
- Capture number of records and oldest record in the `sensor_data` table
- Create data retention policy so data older than 1 month is deleted
- Wait for the first successful run of the retention job
- Capture number of records and oldest record in the `sensor_data` again
- Compare with the previous data
```

**What to expect:**
- The AI will create a database fork (instant copy) for safe experimentation
- Set up automatic data retention policies
- Demonstrate how old data is automatically removed
- Provide before/after statistics showing the retention policy's effect

### 6. Database Optimization

Use AI agents to analyze your database configuration and identify optimization opportunities.

**Prompt:**

```text
Check the chunk sizes, segment_by and suggest optimizations for better performance.
```

**What to expect:**
- Analysis of TimescaleDB hypertable chunk sizes
- Evaluation of partition key and segment_by column choices
- Specific recommendations for performance improvements
- Rationale for each suggested optimization

## Additional Resources

- [TimescaleDB Documentation](https://docs.timescale.com/)
- [Tiger CLI GitHub Repository](https://github.com/timescale/tiger-cli)
- [TigerData Cloud Console](https://console.tigerdata.com/)
- [Model Context Protocol (MCP) Specification](https://modelcontextprotocol.io/)

## Troubleshooting

**Issue:** AI assistant doesn't have access to Tiger MCP tools

**Solution:**
1. Verify Tiger CLI is installed: `tiger version`
2. Authenticate Tiger CLI to connect it to Tiger project `tiger auth login`
2. Reinstall MCP integration: `tiger mcp install`
3. Restart your AI assistant tool
4. Check tool-specific configuration files

**Issue:** Database connection errors

**Solution:**
1. Verify authentication: `tiger auth login`
2. List services: `tiger service list`
3. Check service status in the Tiger Cloud console

**Issue:** Data generation script fails

**Solution:**
1. Ensure Python 3.x is installed: `python --version`
2. Check if required libraries are available
3. Verify write permissions in the current directory

## License

MIT License

## Acknowledgments

This workshop was created by Anton Umnikov/Tiger Data
