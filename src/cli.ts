#!/usr/bin/env bun
import { Command } from 'commander'
import { config } from './config.js'
import { HindsightClient } from './hindsight-client.js'
import { SyncLedger } from './ledger.js'
import { SyncService } from './sync-service.js'
import { AggregatorWatcher } from './watcher.js'

const program = new Command()

program
  .name('ai-aggregator')
  .description('Real-time AI conversation and transcript sync pipeline to Hindsight')
  .version('1.0.0')

program
  .command('status')
  .description('Check Hindsight server health and local sync ledger status')
  .action(async () => {
    const client = new HindsightClient()
    const ledger = new SyncLedger()

    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
    console.log(' AI Aggregator -> Hindsight Status Report')
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
    console.log(`Endpoint: ${config.hindsight.baseUrl}`)
    console.log(`Target Bank: ${config.hindsight.bank}`)
    console.log('')

    // Health check
    process.stdout.write('Checking Hindsight connection... ')
    const health = await client.checkHealth()
    if (health.healthy) {
      console.log('✓ Healthy (Connected to dev server)')
    } else {
      console.log(`✗ Unreachable: ${health.error}`)
      console.log('Tip: Check if the tunnel is running with `bun run tunnel` or `curl http://127.0.0.1:18925/health`')
    }

    // Ledger Stats
    const stats = ledger.getStats()
    ledger.updateStatusFile({ healthy: health.healthy })
    console.log('')
    console.log('Local Ledger Statistics:')
    console.log(`  • Total tracked conversations: ${stats.total}`)
    console.log(`  • Successfully synced:         ${stats.synced}`)
    console.log(`  • Failed / Pending retry:      ${stats.failed}`)

    // File discovery check
    const syncService = new SyncService(client, ledger)
    const discovered = syncService.findConversationFiles()
    console.log('')
    console.log(`Discovered on disk: ${discovered.length} conversation.md files in ${config.paths.aiVaultData}`)
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')

    ledger.close()
  })

program
  .command('sync')
  .description('Run a batch backfill of conversation transcripts into Hindsight')
  .option('-l, --limit <number>', 'Limit number of conversations to sync', parseInt)
  .option('-f, --force', 'Force re-sync even if content hash matches')
  .option('-p, --provider <name>', 'Filter by provider (chatgpt, claude)')
  .option('-v, --verbose', 'Print verbose error details')
  .action(async (options) => {
    const client = new HindsightClient()
    const ledger = new SyncLedger()
    const syncService = new SyncService(client, ledger)

    console.log('Connecting to Hindsight...')
    const health = await client.checkHealth()
    if (!health.healthy) {
      console.error(`Error: Cannot reach Hindsight at ${config.hindsight.baseUrl}: ${health.error}`)
      process.exit(1)
    }

    console.log(`Starting backfill to bank: ${config.hindsight.bank}...`)
    if (options.limit) console.log(`Limit: ${options.limit}`)
    if (options.provider) console.log(`Provider filter: ${options.provider}`)
    if (options.force) console.log('Force re-sync: Enabled')

    const summary = await syncService.runSync({
      limit: options.limit,
      force: options.force,
      verbose: options.verbose,
      provider: options.provider,
    })

    console.log('')
    console.log('═══════════════════════════════════════════════════')
    console.log(' Backfill Summary')
    console.log('═══════════════════════════════════════════════════')
    console.log(`  Files Discovered:   ${summary.discovered}`)
    console.log(`  Already Up-to-Date: ${summary.alreadyUpToDate}`)
    console.log(`  Newly Synced:       ${summary.synced}`)
    console.log(`  Failed:             ${summary.failed}`)
    console.log(`  Async Operations:   ${summary.operations.length}`)
    console.log(`  Duration:           ${(summary.durationMs / 1000).toFixed(2)}s`)
    console.log('═══════════════════════════════════════════════════')

    ledger.close()
  })

program
  .command('watch')
  .description('Start the real-time file watcher daemon')
  .option('--no-initial-sync', 'Skip initial backfill sweep on start')
  .action(async (options) => {
    const client = new HindsightClient()
    const ledger = new SyncLedger()
    const syncService = new SyncService(client, ledger)

    console.log('Checking Hindsight connection before starting watcher...')
    const health = await client.checkHealth()
    if (!health.healthy) {
      console.error(`Warning: Cannot reach Hindsight at ${config.hindsight.baseUrl}: ${health.error}`)
      console.error('The watcher will continue running and retry when Hindsight is available.')
    } else {
      console.log('✓ Connected to Hindsight')
    }

    if (options.initialSync) {
      console.log('\nRunning initial sync sweep...')
      const summary = await syncService.runSync()
      console.log(`Initial sweep complete: ${summary.synced} synced, ${summary.alreadyUpToDate} already up-to-date, ${summary.failed} failed.\n`)
    }

    const watcher = new AggregatorWatcher(syncService)
    watcher.start([config.paths.aiVaultData])

    const cleanup = () => {
      console.log('\nShutting down watcher...')
      watcher.stop()
      ledger.close()
      process.exit(0)
    }

    process.on('SIGINT', cleanup)
    process.on('SIGTERM', cleanup)
  })

program.parse(process.argv)
