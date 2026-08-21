import { MeshOverview } from '@/components/visual/istio/MeshOverview';
import { GatewaysView } from '@/components/visual/istio/GatewaysView';
import { TrafficView } from '@/components/visual/istio/TrafficView';
import { WaypointView } from '@/components/visual/istio/WaypointView';
import { MulticlusterView } from '@/components/visual/istio/MulticlusterView';
import { AIGatewayView } from '@/components/visual/istio/AIGatewayView';
import { ObservabilityView } from '@/components/visual/istio/ObservabilityView';
import { CommandCenter } from '@/components/visual/CommandCenter';
import { CrossClusterDemo } from '@/components/visual/CrossClusterDemo';

interface VisualDashboardProps {
  activePath: string;
}

/**
 * Visual mode = the Istio 1.30 ambient mesh built in 07-istio-advanced/.
 *
 * Six previous components were retired (AmbientMesh, Observability, Diagnostics,
 * TrafficManagement, SecurityCenter, ServiceManagement): none made an API call,
 * and several hardcoded invented pod names and IPs for a target-cluster mesh
 * that no longer exists. Everything below reads live cluster state.
 *
 * CommandCenter survives as `topology` — it is real, backed by
 * /api/v1/mesh/topology with a force-directed layout.
 *
 * CrossClusterDemo is kept as `demo`: it walks the legacy 05-istio ServiceEntry
 * approach, which is preserved on purpose as the contrast to Act 3.
 */
export function VisualDashboard({ activePath }: VisualDashboardProps) {
  switch (activePath) {
    case 'overview':
      return <MeshOverview />;
    case 'topology':
      return <CommandCenter />;
    case 'gateways':
      return <GatewaysView />;
    case 'traffic':
      return <TrafficView />;
    case 'waypoint':
      return <WaypointView />;
    case 'multicluster':
      return <MulticlusterView />;
    case 'ai-gateway':
      return <AIGatewayView />;
    case 'observability':
      return <ObservabilityView />;
    case 'demo':
      return <CrossClusterDemo />;
    default:
      return <MeshOverview />;
  }
}
