import { useState, useCallback, useEffect } from 'react';
import { MessageList } from './MessageList';
import { ChatInput } from './ChatInput';
import { SuggestedPrompts } from './SuggestedPrompts';
import { api } from '@/lib/api';
import type { AgentInfo } from '@/lib/api';
import type { ChatMessage, Proposal } from '@/lib/types';
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
        setAgents([{ name: 'cluster2-agent', description: 'Cluster2 management-plane agent' }]);
        setSelectedAgent('cluster2-agent');
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
    const assistantId = crypto.randomUUID();
    const assistantMsg: ChatMessage = {
      id: assistantId,
      role: 'assistant',
      content: '',
      timestamp: new Date(),
    };

    // Build the rolling history we'll send to the backend (text-only).
    // Messages array as it stands BEFORE we add the new user/assistant pair.
    const history = messages
      .filter((m) => m.role === 'user' || (m.role === 'assistant' && m.content))
      .map((m) => ({ role: m.role, content: m.content }));
    history.push({ role: 'user', content: text });

    setMessages((prev) => [...prev, userMsg, assistantMsg]);
    setStreaming(true);

    try {
      for await (const env of api.sendChat(history, selectedAgent)) {
        if (env.type === 'text') {
          setMessages((prev) =>
            prev.map((m) =>
              m.id === assistantId ? { ...m, content: m.content + env.text } : m,
            ),
          );
        } else if (env.type === 'proposal') {
          setMessages((prev) =>
            prev.map((m) =>
              m.id === assistantId
                ? { ...m, proposal: env.proposal, proposalStatus: 'pending' }
                : m,
            ),
          );
        } else if (env.type === 'error') {
          setMessages((prev) =>
            prev.map((m) =>
              m.id === assistantId
                ? { ...m, content: m.content + `\n\n_${env.error}_` }
                : m,
            ),
          );
        }
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
  }, [selectedAgent, messages]);

  const approveProposal = useCallback(async (messageId: string, proposal: Proposal) => {
    setMessages((prev) =>
      prev.map((m) =>
        m.id === messageId ? { ...m, proposalStatus: 'approved', toolSteps: [] } : m,
      ),
    );
    setStreaming(true);
    try {
      for await (const env of api.executeAction(proposal)) {
        if (env.type === 'tool_step') {
          setMessages((prev) =>
            prev.map((m) =>
              m.id === messageId
                ? { ...m, toolSteps: [...(m.toolSteps ?? []), env.step] }
                : m,
            ),
          );
        } else if (env.type === 'text') {
          setMessages((prev) =>
            prev.map((m) =>
              m.id === messageId ? { ...m, content: m.content + env.text } : m,
            ),
          );
        } else if (env.type === 'error') {
          setMessages((prev) =>
            prev.map((m) =>
              m.id === messageId
                ? { ...m, content: m.content + `\n\n_${env.error}_` }
                : m,
            ),
          );
        }
      }
    } catch (e) {
      setMessages((prev) =>
        prev.map((m) =>
          m.id === messageId
            ? { ...m, content: m.content + `\n\n_Action failed: ${(e as Error).message}_` }
            : m,
        ),
      );
    } finally {
      setStreaming(false);
    }
  }, []);

  const rejectProposal = useCallback((messageId: string) => {
    setMessages((prev) =>
      prev.map((m) =>
        m.id === messageId ? { ...m, proposalStatus: 'rejected' } : m,
      ),
    );
  }, []);

  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center gap-2 border-b px-4 py-2">
        <label htmlFor="agent-select" className="text-xs font-medium text-muted-foreground">
          Agent:
        </label>
        <select
          id="agent-select"
          value={selectedAgent}
          onChange={(e) => setSelectedAgent(e.target.value)}
          disabled={streaming || agentsLoading}
          className="rounded-md border bg-background text-foreground px-2 py-1 text-sm"
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
            <h2 className="text-xl font-semibold text-foreground">KubeUI Assistant</h2>
            <p className="mt-1 text-sm text-muted-foreground">
              Powered by Sympozium ({selectedAgent})
            </p>
          </div>
          <SuggestedPrompts onSelect={sendMessage} />
        </div>
      ) : (
        <MessageList
          messages={messages}
          onApproveProposal={approveProposal}
          onRejectProposal={rejectProposal}
        />
      )}
      <ChatInput onSend={sendMessage} disabled={streaming} />
    </div>
  );
}
