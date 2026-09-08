export interface MemoryItem {
  document_id: string
  content: string
  timestamp?: string
  context?: string
  update_mode?: 'replace' | 'append'
  tags?: string[]
  metadata?: Record<string, string>
}

export interface RetainRequest {
  items: MemoryItem[]
  async: boolean
  operation_id?: string
}

export interface RetainResponse {
  success: boolean
  bank_id: string
  items_count: number
  async: boolean
  operation_id?: string
  message?: string
}

export interface OperationStatus {
  operation_id: string
  status: 'pending' | 'processing' | 'completed' | 'failed'
  operation_type: string
  created_at: string
  completed_at?: string
  result_metadata?: Record<string, unknown>
}

export interface ParsedConversation {
  documentId: string
  provider: 'chatgpt' | 'claude' | 'gemini' | 'unknown'
  conversationId: string
  title: string
  createdAt?: string
  updatedAt?: string
  messageCount: number
  content: string
  contentHash: string
  sourcePath: string
}

export interface LedgerRecord {
  file_path: string
  content_hash: string
  document_id: string
  provider: string
  conversation_id: string
  title: string
  message_count: number
  last_operation_id: string | null
  last_synced_at: string
  sync_status: 'synced' | 'failed'
  error_message: string | null
}
