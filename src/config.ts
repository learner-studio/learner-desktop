import { homedir } from 'node:os'
import { join } from 'node:path'

const HOME = homedir()

export const config = {
  learnerApi: {
    /** RPCs are POSTed to `${baseUrl}/rpc/<name>`. */
    baseUrl: (process.env.LEARNER_API_URL || 'https://dev.biztoolz.app/learner-api').replace(/\/+$/, ''),
    /** The device key's owner; the server refuses a mismatch. */
    clientId: 'ben-mbp',
    /** Keychain item holding the device key when LEARNER_API_KEY is not set. */
    keychainService: 'learner-server',
    keychainAccount: 'ben-mbp',
    requestTimeoutMs: 60_000,
  },
  paths: {
    aiVaultData: process.env.AI_VAULT_DATA || join(HOME, 'ai-vault-data'),
    ledgerDb: process.env.LEDGER_DB || join(HOME, '.ai-aggregator', 'sync-ledger.sqlite'),
  },
  sync: {
    /** archiveConversationDocuments takes at most 50 documents per call. */
    batchSize: 50,
    debounceMs: 500,
    /** 429 / 5xx / network: exponential backoff from 2 s, capped at 5 min, with jitter. */
    backoffInitialMs: 2_000,
    backoffMaxMs: 300_000,
    /** No key, or the key was refused: try the pending work again after this long. */
    retryLaterMs: 600_000,
  },
}
