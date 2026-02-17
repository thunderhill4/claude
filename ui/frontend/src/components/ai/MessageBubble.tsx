import { cn } from '@/lib/utils';
import { ResourceCard } from './ResourceCard';
import type { ChatMessage } from '@/lib/types';
import { User, Bot } from 'lucide-react';

interface MessageBubbleProps {
  message: ChatMessage;
}

export function MessageBubble({ message }: MessageBubbleProps) {
  const isUser = message.role === 'user';

  return (
    <div className={cn('flex gap-3', isUser ? 'justify-end' : 'justify-start')}>
      {!isUser && (
        <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-primary">
          <Bot className="h-4 w-4 text-primary-foreground" />
        </div>
      )}
      <div className={cn('max-w-[70%] space-y-2', isUser ? 'items-end' : 'items-start')}>
        <div
          className={cn(
            'rounded-2xl px-4 py-2.5 text-sm',
            isUser
              ? 'bg-primary text-primary-foreground'
              : 'bg-secondary text-foreground',
          )}
        >
          <p className="whitespace-pre-wrap">{message.content}</p>
        </div>
        {message.resources?.map((r, i) => (
          <ResourceCard key={i} resource={r} />
        ))}
      </div>
      {isUser && (
        <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-accent">
          <User className="h-4 w-4 text-accent-foreground" />
        </div>
      )}
    </div>
  );
}
