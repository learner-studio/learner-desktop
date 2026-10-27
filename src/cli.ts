#!/usr/bin/env bun
import { Command } from 'commander'
import { config } from './config.js'
import { LearnerApiClient } from './learner-api.js'
import { SyncLedger } from './ledger.js'
import { SyncService, type SyncSummary } from './sync-service.js'
import { AggregatorWatcher } from './watcher.js'
import { readFileSync } from 'node:fs'
import { findConversationFiles } from './parsers/ai-vault-messages.js'
import { fillVoiceTranscripts, hasVoiceGaps } from './voice-transcripts.js'

const program = new Command()

program
  .name('learner-watcher')
  .description('Archive ai-vault conversations to learner-server (archiveConversationDocuments RPC)')
  .version('2.0.0')

function printSummary(s: SyncSummary): void {
  console.log(`  Files discovered:   ${s.discovered}`)
  console.log(`  Already up to date: ${s.alreadyUpToDate}`)
  console.log(`  No text messages:   ${s.emptySkipped}`)
  console.log(`  Unreadable:         ${s.parseFailed}`)
  console.log(`  Archived:           ${s.synced}`)
  console.log(`  Parked (refused):   ${s.parked}`)
  console.log(`  RPC requests:       ${s.requests}`)
  if (s.stopped) console.log(`  Stopped early:      ${s.stopped} (${s.remaining} not sent)`)
  console.log(`  Duration:           ${(s.durationMs / 1000).toFixed(2)}s`)
}

program
  .command('status')
  .description('Show the endpoint, whether a device key is available, and the local ledger counts')
  .action(() => {
    const api = new LearnerApiClient()
    const ledger = new SyncLedger()
    const service = new SyncService(api, ledger)
    const stats = ledger.getStats()
    console.log(`Endpoint:    ${api.baseUrl}/rpc/archiveConversationDocuments`)
    console.log(`Client id:   ${api.clientId}`)
    console.log(`Device key:  ${api.hasKey() ? 'available' : 'MISSING (set LEARNER_API_KEY or Keychain learner-server/ben-mbp)'}`)
    console.log(`Ledger:      ${stats.total} tracked, ${stats.synced} archived, ${stats.failed} parked, ${stats.skipped} without text`)
    console.log(`On disk:     ${service.findConversationFiles().length} conversation.md files in ${config.paths.aiVaultData}`)
    ledger.updateStatusFile()
    ledger.close()
  })

program
  .command('sync')
  .description('Archive every conversation whose content changed since it was last sent')
  .option('-l, --limit <number>', 'Only consider the first N files', (v) => parseInt(v, 10))
  .option('-f, --force', 'Resend even if the content hash matches')
  .option('-p, --provider <name>', 'Only one provider directory (chatgpt, claude, gemini)')
  .action(async (options) => {
    const ledger = new SyncLedger()
    const service = new SyncService(new LearnerApiClient(), ledger)
    const summary = await service.runSync({ limit: options.limit, force: options.force, provider: options.provider })
    printSummary(summary)
    ledger.close()
    process.exit(summary.stopped ? 1 : 0)
  })

program
  .command('watch')
  .description('Watch the ai-vault export and archive conversations as they change')
  .action(async () => {
    const ledger = new SyncLedger()
    const service = new SyncService(new LearnerApiClient(), ledger)
    ledger.updateStatusFile()

    const watcher = new AggregatorWatcher(service)
    watcher.start([config.paths.aiVaultData])

    // File events only cover changes made while watching. A full sweep on start catches
    // what was exported while the watcher was down (and any retries a restart dropped);
    // the hourly one covers events macOS drops. Unchanged files cost a hash each.
    const sweep = (why: string) => {
      console.log(`[Watcher] ${why} sweep`)
      service.enqueue(service.findConversationFiles()).catch((err) => {
        console.error(`[Watcher] ${why} sweep failed: ${(err as Error).message}`)
      })
    }
    sweep('startup')
    const hourly = setInterval(() => sweep('hourly'), config.sync.sweepIntervalMs)

    const cleanup = () => {
      console.log('\nShutting down watcher...')
      clearInterval(hourly)
      watcher.stop()
      ledger.close()
      process.exit(0)
    }
    process.on('SIGINT', cleanup)
    process.on('SIGTERM', cleanup)
  })

program
  .command('voice-transcripts')
  .description('Write the ChatGPT voice-chat transcripts ai-vault leaves out into conversation.md')
  .option('-l, --limit <number>', 'At most N conversations', (v) => parseInt(v, 10))
  .option('--delay <ms>', 'Pause between ChatGPT requests', (v) => parseInt(v, 10), 3000)
  .option('--dry-run', 'Only count the conversations that need transcripts')
  .action(async (options) => {
    const files = findConversationFiles(config.paths.aiVaultData, 'chatgpt')
    if (options.dryRun) {
      const n = files.filter((f) => hasVoiceGaps(readFileSync(f, 'utf8'))).length
      console.log(`[Voice] ${n} of ${files.length} ChatGPT conversations have voice messages without text`)
      return
    }
    let s
    try {
      s = await fillVoiceTranscripts(files, { delayMs: options.delay, limit: options.limit, log: console.log })
    } catch (err) {
      // e.g. "ChatGPT login expired": exit non-zero so the app counts the run as failed.
      console.log(`[Voice] could not run: ${(err as Error).message}`)
      process.exit(1)
    }
    console.log(
      `[Voice] ${s.candidates} conversations need transcripts: ${s.updated} updated (${s.filled} messages), ` +
        `${s.missing} messages without a transcript, ${s.failed} failed` + (s.stopped ? `; stopped: ${s.stopped}` : ''),
    )
    process.exit(s.stopped ? 2 : 0)
  })

// A watcher that dies stops archiving; log and keep going instead.
process.on('unhandledRejection', (err) => console.error(`[learner-watcher] unhandled: ${(err as Error)?.message ?? err}`))

program.parse(process.argv)
