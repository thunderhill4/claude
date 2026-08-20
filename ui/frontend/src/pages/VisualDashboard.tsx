import { CommandCenter } from '@/components/visual/CommandCenter';
import { TopologyView } from '@/components/visual/TopologyView';
import { CrossClusterDemo } from '@/components/visual/CrossClusterDemo';
import { ServiceManagement } from '@/components/visual/ServiceManagement';
import { TrafficManagement } from '@/components/visual/TrafficManagement';
import { SecurityCenter } from '@/components/visual/SecurityCenter';
import { Observability } from '@/components/visual/Observability';
import { AmbientMesh } from '@/components/visual/AmbientMesh';
import { Diagnostics } from '@/components/visual/Diagnostics';

interface VisualDashboardProps {
  activePath: string;
}

export function VisualDashboard({ activePath }: VisualDashboardProps) {
  switch (activePath) {
    case 'command':
      return <CommandCenter />;
    case 'topology':
      return <TopologyView />;
    case 'demo':
      return <CrossClusterDemo />;
    case 'services':
      return <ServiceManagement />;
    case 'traffic':
      return <TrafficManagement />;
    case 'security':
      return <SecurityCenter />;
    case 'observability':
      return <Observability />;
    case 'ambient':
      return <AmbientMesh />;
    case 'diagnostics':
      return <Diagnostics />;
    default:
      return <CommandCenter />;
  }
}
