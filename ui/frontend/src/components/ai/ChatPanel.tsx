import { useState, useCallback } from 'react';
import { MessageList } from './MessageList';
import { ChatInput } from './ChatInput';
import { SuggestedPrompts } from './SuggestedPrompts';
import { api } from '@/lib/api';
import type { ChatMessage } from '@/lib/types';
import { Bot } from 'lucide-react';

export function ChatPanel() {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [streaming, setStreaming] = useState(false);

  const sendMessage = useCallback(async (text: string) => {
    const userMsg: ChatMessage = {
      id: crypto.randomUUID(),
      role: 'user',
      content: text,
      timestamp: new Date(),
    };
    setMessages((prev) => [...prev, userMsg]);
    setStreaming(true);

    const assistantId = crypto.randomUUID();
    const assistantMsg: ChatMessage = {
      id: assistantId,
      role: 'assistant',
      content: '',
      timestamp: new Date(),
    };
    setMessages((prev) => [...prev, assistantMsg]);

    try {
      for await (const chunk of api.sendChat(text)) {
        setMessages((prev) =>
          prev.map((m) =>
            m.id === assistantId ? { ...m, content: m.content + chunk } : m,
          ),
        );
      }
    } catch {
      setMessages((prev) =>
        prev.map((m) =>
          m.id === assistantId
            ? { ...m, content: 'Sorry, I encountered an error. Please try again.' }
            : m,
        ),
      );
    } finally {
      setStreaming(false);
    }
  }, []);

  return (
    <div className="flex h-full flex-col">
      {messages.length === 0 ? (
        <div className="flex flex-1 flex-col items-center justify-center gap-6 p-8">
          <div className="flex h-16 w-16 items-center justify-center rounded-full bg-primary">
            <Bot className="h-8 w-8 text-primary-foreground" />
          </div>
          <div className="text-center">
            <h2 className="text-xl font-semibold">KubeUI Assistant</h2>
            <p className="mt-1 text-sm text-muted-foreground">
              Ask questions about your cluster resources
            </p>
          </div>
          <SuggestedPrompts onSelect={sendMessage} />
        </div>
      ) : (
        <MessageList messages={messages} />
      )}
      <ChatInput onSend={sendMessage} disabled={streaming} />
    </div>
  );
}
