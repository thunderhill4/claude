import { useState, useCallback, useEffect } from 'react';
import { MessageList } from './MessageList';
import { ChatInput } from './ChatInput';
import { SuggestedPrompts } from './SuggestedPrompts';
import { api } from '@/lib/api';
import type { AgentInfo } from '@/lib/api';
import type { ChatMessage } from '@/lib/types';
import { Bot } from 'lucide-react';

export function ChatPanel() {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [streaming, setStreaming] = useState(false);
  const [agents, setAgents] = useState<AgentInfo[]>([]);
  const [selectedAgent, setSelectedAgent] = useState('');
  const [agentsLoading, setAgentsLoading] = useState(true);

  useEffect(() => {
    api.getAgents()
      .then((data) => {
        setAgents(data.agents);
        setSelectedAgent(data.default);
      })
      .catch(() => {
        // Fallback if kagent controller is unreachable
        setAgents([{ name: 'k8s-agent', description: 'Kubernetes cluster diagnostics' }]);
        setSelectedAgent('k8s-agent');
      })
      .finally(() => setAgentsLoading(false));
  }, []);

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
      for await (const chunk of api.sendChat(text, selectedAgent)) {
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
  }, [selectedAgent]);

  return (
    <div className="flex h-full flex-col">
      {/* Agent selector */}
      <div className="flex items-center gap-2 border-b px-4 py-2">
        <label htmlFor="agent-select" className="text-xs font-medium text-muted-foreground">
          Agent:
        </label>
        <select
          id="agent-select"
          value={selectedAgent}
          onChange={(e) => setSelectedAgent(e.target.value)}
          disabled={streaming || agentsLoading}
          className="rounded-md border bg-background px-2 py-1 text-sm"
        >
          {agents.map((a) => (
            <option key={a.name} value={a.name}>
              {a.name}
            </option>
          ))}
        </select>
        {agents.find((a) => a.name === selectedAgent)?.description && (
          <span className="text-xs text-muted-foreground">
            — {agents.find((a) => a.name === selectedAgent)?.description}
          </span>
        )}
      </div>

      {messages.length === 0 ? (
        <div className="flex flex-1 flex-col items-center justify-center gap-6 p-8">
          <div className="flex h-16 w-16 items-center justify-center rounded-full bg-primary">
            <Bot className="h-8 w-8 text-primary-foreground" />
          </div>
          <div className="text-center">
            <h2 className="text-xl font-semibold">KubeUI Assistant</h2>
            <p className="mt-1 text-sm text-muted-foreground">
              Powered by kagent ({selectedAgent}) using Ollama/llama3.2
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
