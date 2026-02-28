import { Dashboard } from '@/components/sre/Dashboard';
import { NodeList } from '@/components/sre/NodeList';
import { PodList } from '@/components/sre/PodList';
import { VMList } from '@/components/sre/VMList';
import { EventList } from '@/components/sre/EventList';
import { ClusterManager } from '@/components/sre/ClusterManager';
import { Registry } from '@/components/sre/Registry';
import { ImageRepo } from '@/components/sre/ImageRepo';

interface SREDashboardProps {
  activePath: string;
  namespace: string;
}

export function SREDashboard({ activePath, namespace }: SREDashboardProps) {
  switch (activePath) {
    case 'dashboard':
      return <Dashboard />;
    case 'nodes':
      return <NodeList />;
    case 'pods':
      return <PodList namespace={namespace} />;
    case 'vms':
      return <VMList namespace={namespace} />;
    case 'events':
      return <EventList namespace={namespace} />;
    case 'cluster':
      return <ClusterManager />;
    case 'registry':
      return <Registry />;
    case 'images':
      return <ImageRepo />;
    default:
      return <Dashboard />;
  }
}
