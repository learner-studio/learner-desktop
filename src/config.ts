import { homedir } from 'node:os'
import { join } from 'node:path'

const HOME = homedir()

export const config = {
  hindsight: {
    baseUrl: process.env.HINDSIGHT_URL || 'http://127.0.0.1:18925',
    bank: process.env.HINDSIGHT_BANK || 'learning-transcript-archive-v1',
    requestTimeoutMs: 30_000,
    maxRetries: 3,
  },
  paths: {
    aiVaultData: process.env.AI_VAULT_DATA || join(HOME, 'ai-vault-data'),
    claudeProjects: process.env.CLAUDE_PROJECTS || join(HOME, '.claude', 'projects'),
    geminiBrain: process.env.GEMINI_BRAIN || join(HOME, '.gemini', 'antigravity', 'brain'),
    ledgerDb: process.env.LEDGER_DB || join(HOME, '.ai-aggregator', 'sync-ledger.sqlite'),
  },
  sync: {
    batchSize: 25,
    debounceMs: 500,
    batchDelayMs: 200,
  },
}
