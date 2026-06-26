import { useEffect, useRef } from 'react';
import { ScrollArea } from '@/components/ui/scroll-area';
import { MessageBubble } from './MessageBubble';
import type { ChatMessage, Proposal } from '@/lib/types';

interface MessageListProps {
  messages: ChatMessage[];
  onApproveProposal?: (messageId: string, proposal: Proposal) => void;
  onRejectProposal?: (messageId: string) => void;
}

export function MessageList({ messages, onApproveProposal, onRejectProposal }: MessageListProps) {
  const bottomRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  return (
    <ScrollArea className="flex-1 px-4">
      <div className="mx-auto max-w-3xl space-y-4 py-6">
        {messages.map((msg) => (
          <MessageBubble
            key={msg.id}
            message={msg}
            onApproveProposal={onApproveProposal}
            onRejectProposal={onRejectProposal}
          />
        ))}
        <div ref={bottomRef} />
      </div>
    </ScrollArea>
  );
}
