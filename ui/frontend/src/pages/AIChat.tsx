import { AgentConsole } from '@/components/ai/AgentConsole';

// The AI tab embeds the de-branded agent console (chat + side panes come from
// the console itself); kubeui's ChatPanel is not routed here.
export function AIChat() {
  return <AgentConsole />;
}
