import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { ArrowLeft } from 'lucide-react';
import type { VirtualMachine } from '@/lib/types';

interface VMDetailProps {
  vm: VirtualMachine;
  onBack: () => void;
}

export function VMDetail({ vm, onBack }: VMDetailProps) {
  const statusColor = vm.status === 'Running' ? 'default' : vm.status === 'Stopped' ? 'secondary' : 'destructive';

  return (
    <div className="space-y-4 p-6">
      <div className="flex items-center gap-3">
        <Button variant="ghost" size="sm" onClick={onBack}>
          <ArrowLeft className="mr-1 h-4 w-4" /> Back
        </Button>
        <h2 className="text-2xl font-bold">{vm.name}</h2>
        <Badge variant={statusColor}>{vm.status}</Badge>
      </div>

      <Tabs defaultValue="overview">
        <TabsList>
          <TabsTrigger value="overview">Overview</TabsTrigger>
          <TabsTrigger value="yaml">YAML</TabsTrigger>
          <TabsTrigger value="events">Events</TabsTrigger>
          <TabsTrigger value="console">Console</TabsTrigger>
        </TabsList>

        <TabsContent value="overview">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Details</CardTitle>
            </CardHeader>
            <CardContent>
              <dl className="grid grid-cols-2 gap-4 text-sm">
                <div>
                  <dt className="text-muted-foreground">Name</dt>
                  <dd className="font-medium">{vm.name}</dd>
                </div>
                <div>
                  <dt className="text-muted-foreground">Namespace</dt>
                  <dd className="font-medium">{vm.namespace}</dd>
                </div>
                <div>
                  <dt className="text-muted-foreground">CPU</dt>
                  <dd className="font-medium">{vm.cpu} cores</dd>
                </div>
                <div>
                  <dt className="text-muted-foreground">Memory</dt>
                  <dd className="font-medium">{vm.memory}</dd>
                </div>
                <div>
                  <dt className="text-muted-foreground">Node</dt>
                  <dd className="font-medium">{vm.node}</dd>
                </div>
                <div>
                  <dt className="text-muted-foreground">IP Address</dt>
                  <dd className="font-medium">{vm.ipAddress}</dd>
                </div>
                <div>
                  <dt className="text-muted-foreground">Age</dt>
                  <dd className="font-medium">{vm.age}</dd>
                </div>
              </dl>
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="yaml">
          <Card>
            <CardContent className="pt-6">
              <pre className="rounded-md bg-secondary p-4 text-xs">
                {`apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${vm.name}
  namespace: ${vm.namespace}
spec:
  running: ${vm.status === 'Running'}
  template:
    spec:
      domain:
        cpu:
          cores: ${vm.cpu}
        resources:
          requests:
            memory: ${vm.memory}
      networks:
        - name: default
          pod: {}`}
              </pre>
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="events">
          <Card>
            <CardContent className="pt-6 text-sm text-muted-foreground">
              Events will appear here when connected to a live cluster.
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="console">
          <Card>
            <CardContent className="pt-6">
              <div className="flex h-64 items-center justify-center rounded-md bg-black text-green-400 font-mono text-sm">
                Console access requires VNC/serial proxy connection
              </div>
            </CardContent>
          </Card>
        </TabsContent>
      </Tabs>
    </div>
  );
}
