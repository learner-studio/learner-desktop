#!/usr/bin/env bun
/**
 * Parse every ai-vault conversation.md into messages and print counts only (never text).
 *
 *   bun scripts/vault-messages-report.ts [root]     # default: $AI_VAULT_DATA or ~/ai-vault-data
 */
import { homedir } from 'node:os'
import { join } from 'node:path'
import { findConversationFiles, parseConversationFile } from '../src/parsers/ai-vault-messages.js'

const root = process.argv[2] || process.env.AI_VAULT_DATA || join(homedir(), 'ai-vault-data')
const files = findConversationFiles(root)

const totals = { files: 0, valid: 0, invalid: 0, messages: 0, user: 0, assistant: 0, skipped: 0, attachments: 0 }
const byProvider = new Map<string, number>()
const skippedByReason = new Map<string, number>()
const flagged: { provider: string; id: string; reasons: string[] }[] = []

console.log(['provider', 'conversation_id', 'messages', 'user', 'assistant', 'skipped', 'status'].join('\t'))
for (const file of files) {
  const r = parseConversationFile(file)
  totals.files++
  byProvider.set(r.provider, (byProvider.get(r.provider) ?? 0) + 1)
  const n = r.document?.messages.length ?? 0
  totals.messages += n
  totals.user += r.stats.user
  totals.assistant += r.stats.assistant
  totals.skipped += r.stats.skipped
  totals.attachments += r.stats.attachments
  for (const [k, v] of Object.entries(r.stats.skippedByReason)) skippedByReason.set(k, (skippedByReason.get(k) ?? 0) + (v ?? 0))
  if (r.document) totals.valid++
  else totals.invalid++

  const reasons = [...r.problems]
  for (const [k, v] of Object.entries(r.stats.skippedByReason)) reasons.push(`skipped-${k}:${v}`)
  if (r.stats.truncated) reasons.push(`truncated:${r.stats.truncated}`)
  if (reasons.length) flagged.push({ provider: r.provider, id: r.conversationId, reasons })

  const status = r.document ? (reasons.length ? 'valid,flagged' : 'valid') : 'INVALID'
  console.log([r.provider, r.conversationId, n, r.stats.user, r.stats.assistant, r.stats.skipped, status].join('\t'))
}

console.log('')
console.log(`root: ${root}`)
console.log(`files: ${totals.files} (${[...byProvider].map(([p, c]) => `${p}=${c}`).join(', ') || 'none'})`)
console.log(`documents: valid=${totals.valid} invalid=${totals.invalid}`)
console.log(`messages: total=${totals.messages} user=${totals.user} assistant=${totals.assistant}`)
console.log(
  `skipped messages: ${totals.skipped}` +
    (skippedByReason.size ? ` (${[...skippedByReason].map(([k, v]) => `${k}=${v}`).join(', ')})` : ''),
)
console.log(`attachments stripped: ${totals.attachments}`)
console.log(`flagged files: ${flagged.length}`)
for (const f of flagged) console.log(`  ${f.provider}:${f.id}  ${f.reasons.join(' ')}`)

process.exit(totals.invalid > 0 ? 1 : 0)
