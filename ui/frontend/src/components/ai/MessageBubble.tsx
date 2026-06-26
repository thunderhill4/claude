import { cn } from '@/lib/utils';
import { ResourceCard } from './ResourceCard';
import type { ChatMessage, Proposal, DeployLogEntry } from '@/lib/types';
import { User, Bot, CheckCircle2, XCircle, Rocket, Loader2 } from 'lucide-react';
import Markdown from 'react-markdown';
import remarkGfm from 'remark-gfm';

interface MessageBubbleProps {
  message: ChatMessage;
  onApproveProposal?: (messageId: string, proposal: Proposal) => void;
  onRejectProposal?: (messageId: string) => void;
}

export function MessageBubble({ message, onApproveProposal, onRejectProposal }: MessageBubbleProps) {
  const isUser = message.role === 'user';

  // Hide the raw fenced JSON block from the rendered text so users don't see it.
  const cleanedContent = isUser
    ? message.content
    : message.content.replace(/```json\s*\{[\s\S]*?\}\s*```/g, '').trim();

  return (
    <div className={cn('flex gap-3', isUser ? 'justify-end' : 'justify-start')}>
      {!isUser && (
        <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-primary">
          <Bot className="h-4 w-4 text-primary-foreground" />
        </div>
      )}
      <div className={cn('max-w-[70%] space-y-2', isUser ? 'items-end' : 'items-start')}>
        {cleanedContent && (
          <div
            className={cn(
              'rounded-2xl px-4 py-2.5 text-sm',
              isUser
                ? 'bg-primary text-primary-foreground'
                : 'bg-secondary text-foreground',
            )}
          >
            {isUser ? (
              <p className="whitespace-pre-wrap">{cleanedContent}</p>
            ) : (
              <div className="prose prose-sm max-w-none dark:prose-invert prose-pre:bg-muted prose-code:text-foreground">
                <Markdown remarkPlugins={[remarkGfm]}>{cleanedContent}</Markdown>
              </div>
            )}
          </div>
        )}

        {message.proposal && (
          <ProposalCard
            messageId={message.id}
            proposal={message.proposal}
            status={message.proposalStatus ?? 'pending'}
            onApprove={onApproveProposal}
            onReject={onRejectProposal}
          />
        )}

        {message.toolSteps && message.toolSteps.length > 0 && (
          <ToolSteps steps={message.toolSteps} />
        )}

        {message.resources?.map((r, i) => <ResourceCard key={i} resource={r} />)}
      </div>
      {isUser && (
        <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-accent">
          <User className="h-4 w-4 text-accent-foreground" />
        </div>
      )}
    </div>
  );
}

function ProposalCard({
  messageId,
  proposal,
  status,
  onApprove,
  onReject,
}: {
  messageId: string;
  proposal: Proposal;
  status: 'pending' | 'approved' | 'rejected';
  onApprove?: (messageId: string, proposal: Proposal) => void;
  onReject?: (messageId: string) => void;
}) {
  const title = humanizeAction(proposal.action);

  return (
    <div className="rounded-lg border border-primary/30 bg-primary/5 p-3 text-sm">
      <div className="flex items-start gap-2">
        <Rocket className="mt-0.5 h-4 w-4 shrink-0 text-primary" />
        <div className="flex-1 space-y-1">
          <div className="font-medium text-foreground">{title}</div>
          {proposal.profile && (
            <div className="text-xs text-muted-foreground">
              Profile: <code className="rounded bg-muted px-1 py-0.5">{proposal.profile}</code>
            </div>
          )}
          {proposal.reason && (
            <div className="text-xs text-muted-foreground">{proposal.reason}</div>
          )}
        </div>
      </div>
      <div className="mt-3 flex items-center gap-2">
        {status === 'pending' && (
          <>
            <button
              onClick={() => onApprove?.(messageId, proposal)}
              className="inline-flex items-center gap-1 rounded-md bg-primary px-3 py-1 text-xs font-medium text-primary-foreground hover:bg-primary/90"
            >
              <CheckCircle2 className="h-3.5 w-3.5" /> Approve
            </button>
            <button
              onClick={() => onReject?.(messageId)}
              className="inline-flex items-center gap-1 rounded-md border bg-background px-3 py-1 text-xs font-medium text-foreground hover:bg-muted"
            >
              <XCircle className="h-3.5 w-3.5" /> Reject
            </button>
          </>
        )}
        {status === 'approved' && (
          <span className="inline-flex items-center gap-1 text-xs text-primary">
            <CheckCircle2 className="h-3.5 w-3.5" /> Approved — running
          </span>
        )}
        {status === 'rejected' && (
          <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
            <XCircle className="h-3.5 w-3.5" /> Rejected
          </span>
        )}
      </div>
    </div>
  );
}

function ToolSteps({ steps }: { steps: DeployLogEntry[] }) {
  const last = steps[steps.length - 1];
  const finished = steps.some((s) => s.type === 'done');
  const failed = last?.type === 'error' || last?.message === 'failed';

  return (
    <details
      open={!finished}
      className="rounded-lg border bg-muted/30 p-3 text-xs"
    >
      <summary className="flex cursor-pointer items-center gap-2 font-medium">
        {finished ? (
          failed ? (
            <XCircle className="h-3.5 w-3.5 text-destructive" />
          ) : (
            <CheckCircle2 className="h-3.5 w-3.5 text-primary" />
          )
        ) : (
          <Loader2 className="h-3.5 w-3.5 animate-spin text-primary" />
        )}
        <span>
          🔧 deploy target cluster — {steps.length} log line{steps.length === 1 ? '' : 's'}
        </span>
      </summary>
      <div className="mt-2 max-h-72 overflow-auto font-mono text-[11px] leading-relaxed">
        {steps.map((s, i) => (
          <div
            key={i}
            className={cn(
              'whitespace-pre-wrap',
              s.type === 'error' && 'text-destructive',
              s.type === 'warn' && 'text-yellow-500',
              s.type === 'success' && 'text-primary',
              s.type === 'step' && 'mt-1 font-semibold text-foreground',
            )}
          >
            <span className="text-muted-foreground">{s.time}</span> {s.message}
          </div>
        ))}
      </div>
    </details>
  );
}

function humanizeAction(action: string): string {
  switch (action) {
    case 'deploy_target_cluster':
      return 'Deploy target cluster';
    default:
      return action;
  }
}
