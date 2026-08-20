// Full-page embed of the AI console: the agent dashboard served through the
// backend's de-branding proxy (see ui/backend/handlers/dashboard_proxy.go).
// The proxy hides the vendor top bar and pre-seeds login + namespace, so all
// side panes (Agents, Runs, Schedules, Ensembles, ...) work with no setup.
// Convention: the proxy listens on port 8081 of the same host serving the UI
// (nginx forwards :8081 in the k8s deployment; run-ui.sh backend binds it in dev).
const CONSOLE_PORT = 8081;

export function AgentConsole() {
  const src = `${window.location.protocol}//${window.location.hostname}:${CONSOLE_PORT}/`;
  return <iframe src={src} title="AI Console" className="h-full w-full border-0" />;
}
