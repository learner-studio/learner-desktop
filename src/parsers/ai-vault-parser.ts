import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { basename, dirname } from 'node:path'
import type { MemoryItem, ParsedConversation } from '../types.js'

export function sha256(content: string): string {
  return createHash('sha256').update(content, 'utf8').digest('hex')
}

export function parseAiVaultConversation(filePath: string): ParsedConversation {
  const content = readFileSync(filePath, 'utf8')
  const contentHash = sha256(content)

  // Expected path: .../ai-vault-data/<provider>/conversations/<conversation-id>/conversation.md
  const conversationDir = dirname(filePath)
  const conversationId = basename(conversationDir)
  const conversationsParent = dirname(conversationDir)
  const providerDir = basename(dirname(conversationsParent))
  
  let provider: 'chatgpt' | 'claude' | 'gemini' | 'unknown' = 'unknown'
  if (filePath.includes('/chatgpt/')) provider = 'chatgpt'
  else if (filePath.includes('/claude/')) provider = 'claude'
  else if (filePath.includes('/gemini/')) provider = 'gemini'

  // Extract metadata from markdown headers
  const titleMatch = content.match(/^#\s+(.+)$/m)
  const title = titleMatch ? titleMatch[1].trim() : conversationId

  const providerMatch = content.match(/\*\*Provider:\*\*\s*([a-zA-Z0-9_-]+)/i)
  if (providerMatch && provider === 'unknown') {
    const raw = providerMatch[1].toLowerCase()
    if (raw === 'chatgpt' || raw === 'claude' || raw === 'gemini') {
      provider = raw
    }
  }

  const createdMatch = content.match(/\*\*Created:\*\*\s*([^\n\r]+)/i)
  const createdAt = createdMatch ? createdMatch[1].trim() : undefined

  const updatedMatch = content.match(/\*\*Updated:\*\*\s*([^\n\r]+)/i)
  const updatedAt = updatedMatch ? updatedMatch[1].trim() : undefined

  const messagesMatch = content.match(/\*\*Messages:\*\*\s*(\d+)/i)
  const messageCount = messagesMatch ? parseInt(messagesMatch[1], 10) : 0

  const documentId = `ai-vault:${provider}:${conversationId}`

  return {
    documentId,
    provider,
    conversationId,
    title,
    createdAt,
    updatedAt,
    messageCount,
    content,
    contentHash,
    sourcePath: filePath,
  }
}

export function conversationToMemoryItem(parsed: ParsedConversation): MemoryItem {
  return {
    document_id: parsed.documentId,
    content: parsed.content,
    timestamp: parsed.updatedAt || parsed.createdAt || new Date().toISOString(),
    context: `AI Vault conversation archive: ${parsed.provider} - "${parsed.title}"`,
    update_mode: 'replace',
    tags: [
      'ai-vault',
      parsed.provider,
      'conversation-archive',
      'web-transcript',
    ],
    metadata: {
      provider: parsed.provider,
      conversation_id: parsed.conversationId,
      title: parsed.title,
      message_count: String(parsed.messageCount),
      created_at: parsed.createdAt || '',
      updated_at: parsed.updatedAt || '',
      source_machine: 'macbook-pro',
      source_path: parsed.sourcePath,
      content_hash: parsed.contentHash,
    },
  }
}
