import chokidar from 'chokidar'
import { config } from './config.js'
import type { SyncService } from './sync-service.js'

export class AggregatorWatcher {
  private watcher: chokidar.FSWatcher | null = null
  private debounceTimers: Map<string, Timer> = new Map()

  constructor(private readonly syncService: SyncService) {}

  start(watchPaths: string[] = [config.paths.aiVaultData]): void {
    console.log(`[Watcher] Starting real-time file watcher on:`)
    for (const p of watchPaths) {
      console.log(`  - ${p}`)
    }

    this.watcher = chokidar.watch(watchPaths, {
      ignored: /(^|[\/\\])\..|node_modules/,
      persistent: true,
      ignoreInitial: true,
      awaitWriteFinish: {
        stabilityThreshold: 500,
        pollInterval: 100,
      },
    })

    this.watcher.on('add', (filePath: string) => this.handleFileEvent('add', filePath))
    this.watcher.on('change', (filePath: string) => this.handleFileEvent('change', filePath))
    this.watcher.on('error', (err: unknown) => {
      console.error(`[Watcher] Watcher error: ${(err as Error).message}`)
    })

    console.log(`[Watcher] Active. Listening for new/updated AI conversations...`)
  }

  private handleFileEvent(event: 'add' | 'change', filePath: string): void {
    if (!filePath.endsWith('conversation.md')) return

    const existingTimer = this.debounceTimers.get(filePath)
    if (existingTimer) {
      clearTimeout(existingTimer)
    }

    const timer = setTimeout(async () => {
      this.debounceTimers.delete(filePath)
      try {
        const result = await this.syncService.syncSingleFile(filePath)
        if (result.status === 'synced') {
          console.log(`[Watcher] [${event.toUpperCase()}] Synced -> ${filePath}`)
        } else if (result.status === 'failed') {
          console.error(`[Watcher] [${event.toUpperCase()}] Failed -> ${filePath}: ${result.error}`)
        }
      } catch (err) {
        console.error(`[Watcher] Error handling ${filePath}: ${(err as Error).message}`)
      }
    }, config.sync.debounceMs)

    this.debounceTimers.set(filePath, timer)
  }

  stop(): void {
    if (this.watcher) {
      this.watcher.close()
      this.watcher = null
      console.log(`[Watcher] Stopped.`)
    }
  }
}
