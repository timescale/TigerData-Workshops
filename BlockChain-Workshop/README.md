# Blockchain Workshop: Bitcoin Data Analysis

This workshop demonstrates how to use PostgreSQL and TimescaleDB to analyze Bitcoin blockchain data. You'll learn to work with blockchain transactions, blocks, and addresses using powerful time-series database capabilities.

## Overview

In this workshop, you will:

- Set up a blockchain data schema optimized for time-series analysis
- Load real Bitcoin blockchain data (blocks 900,000-900,999)
- Perform basic blockchain queries to explore transactions and blocks
- Execute advanced analytics to trace Bitcoin flows and miner activities
- Leverage TimescaleDB's hypertables and columnar storage for performance

## Dataset

The workshop uses a subset of Bitcoin blockchain data covering:

- **Time Period**: June 6-13, 2025
- **Block Range**: 900,000 - 900,999
- **Data Size**: ~1,000 blocks with corresponding transactions and inputs/outputs

The dataset includes three main components:

- **Blocks**: Block metadata including height, timestamp, hash, and fees
- **Transactions**: Individual transaction details with values and fees
- **Transaction Inputs/Outputs**: Detailed UTXO data with addresses and values

## Prerequisites

- TigerData Cloud account (get free 30 days at <https://console.cloud.timescale.com/signup>)
- psql CLI installed ([installation guide](https://www.tigerdata.com/blog/how-to-install-psql-on-mac-ubuntu-debian-windows))
- `wget` and `gunzip` installed locally — the script downloads the dataset with `wget` and loads it via `\COPY ... FROM PROGRAM 'gunzip -c ...'`, both of which run on your machine (macOS: `brew install wget`; `gunzip` ships with macOS/Linux)
- Basic understanding of SQL and blockchain concepts

## Data

The workshop is **not** shipped with data — `Bitcoin-BlockChain.sql` downloads it at runtime (via `wget`) into the workshop folder and loads it with `\COPY`:

- `900000_900999_blocks.csv.gz` — block metadata
- `900000_900999_transactions.csv.gz` — transactions
- `900000_900999_tx_vinout.csv.gz` — transaction inputs/outputs

These `.csv.gz` files are downloaded at runtime (from Timescale's public demo-data bucket) and are git-ignored; delete them when you're done.

## Database Schema

The workshop creates three optimized tables:

### 1. Blocks Table

Stores Bitcoin block information with primary key on block height.

### 2. Transactions Table (Hypertable)

- Partitioned by timestamp for time-series optimization
- Includes columnar storage for analytical workloads
- Tracks transaction IDs, values, fees, and coinbase status

### 3. Transaction Inputs/Outputs Table (Hypertable)

- Stores UTXO (Unspent Transaction Output) data
- Partitioned by timestamp with address-based segmentation
- Enables efficient address balance and flow analysis

## Workshop Exercises

### Basic Blockchain Queries

1. **Block Exploration**: Query transactions within specific blocks
2. **Transaction Details**: Examine individual transaction properties
3. **Address Analysis**: Calculate balances and transaction history for Bitcoin addresses

### Advanced Analytics

1. **Bitcoin Flow Tracing**: Track where Bitcoin is sent from specific addresses
2. **Miner Analysis**: Identify block miners and their earnings
3. **Transaction Graph Analysis**: Follow Bitcoin through multiple transactions

### Agentic AI Analysis

1. **AI-Powered Pattern Recognition**: Use MCP (Model Context Protocol) with AI models to discover complex patterns
2. **Automated Transaction Analysis**: Let AI identify suspicious activities, dust spamming, and institutional behaviors
3. **Exchange Activity Detection**: AI-driven identification of exchange-like transaction patterns

### Example Queries

**Find all transactions in a specific block:**

```sql
SELECT * 
FROM transactions 
WHERE block_height = 900500;
```

**Calculate address balance:**

```sql
SELECT sum(value), count(*)
FROM tx_vinout 
WHERE address = 'bc1qjjcn46tmuf3wnpe987u5lpkkgwgv9pc82f6n2gcq7al6d8dyguxs3svvhy';
```

**Trace Bitcoin flows from an address:**

```sql
WITH transactions_out AS (
    SELECT DISTINCT txid, timestamp
    FROM tx_vinout 
    WHERE address = 'bc1qjjcn46tmuf3wnpe987u5lpkkgwgv9pc82f6n2gcq7al6d8dyguxs3svvhy'
        AND type = 'vin'
    ORDER BY timestamp
) 
SELECT address, timestamp, value
FROM tx_vinout
WHERE (txid, timestamp) IN (SELECT txid, timestamp FROM transactions_out)
    AND type = 'vout';
```

## Agentic AI Integration

This workshop includes advanced AI-powered analysis capabilities using Model Context Protocol (MCP) to automatically discover complex blockchain patterns and behaviors.

### Setting Up AI Analysis

To enable agentic AI analysis, configure an MCP postgres agent with an MCP-capable model (such as Claude Desktop):

```json
{
  "mcpServers": {
    "postgres": {
      "command": "npx",
      "args": [
        "@modelcontextprotocol/server-postgres",
        "postgres://tsdbadmin:XXXXXX@YYYYY.ZZZZZ.tsdb.cloud.timescale.com:30688/tsdb?sslmode=require"
      ]
    }
  }
}
```

### AI Analysis Capabilities

The AI agent can automatically identify and analyze:

#### 1. Most Active Bitcoin Addresses and Transaction Patterns

- **Dust Spamming Detection**: Identifies addresses engaged in dust attacks
- **Example Finding**: Address `3Fh5XYeEKzqomEtLnc7155tZ3Dr1aC4CjM` shows dust spamming patterns

#### 2. High-Value Transaction Analysis

- **Institutional Activity**: Detects large Bitcoin consolidations and institutional movements
- **Example Finding**: Address `bc1qx2x5cqhymfcnjtg902ky6u5t5htmt7fvqztdsm028hkrvxcl4t2sjtpd9l` shows multiple 19,000 BTC transactions indicating institutional player activity

#### 3. Exchange-Like Activity Detection

- **Trading Pattern Recognition**: Identifies addresses with exchange-characteristic transaction flows
- **Example Finding**: Address `bc1qrqlamjhy2qp0xj5mxv4sx7ra9qfmfxllf93l26` exhibits typical exchange address behavior

### Sample AI Analysis Questions

Ask your AI agent to analyze the blockchain data with questions like:

1. "Identify the most active Bitcoin addresses and their transaction patterns"
2. "Find the highest value Bitcoin transactions and analyze consolidation patterns"
3. "Detect addresses that exhibit exchange-like activity patterns"
4. "Analyze mining rewards and trace where miners send their Bitcoin"
5. "Identify potential suspicious or anomalous transaction behaviors"

The AI will automatically query the database, analyze patterns, and provide insights about blockchain behaviors that would be difficult to detect manually.

## Getting Started

1. **Connect to your TigerData Cloud instance** using psql
2. **Execute the workshop SQL file**:

   ```bash
   psql -h your-host -U your-username -d your-database -f Bitcoin-BlockChain.sql
   ```

3. **Follow along with the queries** in the SQL file to explore the data
4. **Verify results** using the Bitcoin block explorer: <https://blockexplorer.one/bitcoin/mainnet>

## Key Learning Outcomes

By the end of this workshop, you will understand how to:

- Design efficient schemas for blockchain data analysis
- Utilize TimescaleDB's time-series optimizations for cryptocurrency data
- Perform complex blockchain analytics using SQL
- Trace Bitcoin transactions and analyze address behaviors
- Optimize queries for large-scale blockchain datasets
- Integrate AI agents for automated pattern discovery and anomaly detection
- Use Model Context Protocol (MCP) for advanced blockchain analysis
- Identify suspicious activities, institutional behaviors, and exchange patterns using AI

## Data Source

The dataset is automatically downloaded from TimescaleDB's demo data repository and includes real Bitcoin blockchain data formatted for analytical use.

## Support

For questions or issues with this workshop, please refer to the [TigerData documentation](https://docs.timescale.com/) or reach out to the TigerData community.

---

**Note**: The balance calculations in this workshop reflect only the subset of blockchain data loaded (blocks 900,000-900,999) and may not represent actual current Bitcoin address balances.