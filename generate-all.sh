#!/bin/bash
# Copyright 2021 Google LLC
# Author: Jun Sheng
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     https://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Edit the following section and set the environment variables
export PROJECT_ID=                # Your GCP Project ID
export SERVICE_ID=                # The Service ID created in service monitoring
export SLO_ID=                    # The SLO ID created in service monitoring
export NUM_PROJECT_ID=$(gcloud projects describe ${PROJECT_ID} --format="value(projectNumber)")
export DEMOAPPIMAGE=gcr.io/${PROJECT_ID}/demoapp:1.0
export SLOCHECKAPP=gcr.io/${PROJECT_ID}/slocheck:2.1
export CANARY_SERVICE_NAME=rollout-demo-canary
export STABLE_SERVICE_NAME=rollout-demo-stable
export SLO_SERVICE_NAME=$CANARY_SERVICE_NAME
export K8SNS=default

cat > 00-analysis-slo.yaml <<EOF
# Argo-rollout analyzer using service monitoring
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: gcp-slo-burnrate-check
  namespace: $K8SNS
spec:
  args:
  - name: target_project
  - name: threshold
  - name: defined_slo
  - name: checker_image
    value: ${SLOCHECKAPP}
  metrics:
  - name: test
    provider:
      job:
        spec:
          backoffLimit: 1
          template:
            metadata:
              annotations:
                sidecar.istio.io/inject: "false"
            spec:
              serviceAccountName: slo-reader
              restartPolicy: Never
              containers:
              - env:
                - name: TARGET_PROJECT
                  value: "{{ args.target_project }}"
                - name: THRESHOLD
                  value: "{{ args.threshold }}"
                - name: DEFINEDSLO
                  value: "{{ args.defined_slo }}"
                image: "{{ args.checker_image }}"
                name: ckslo
EOF

cat > xx-optional-analysis-mql.yaml <<EOF
# Argo-rollout analyzer using a MQL query
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: gcp-mql-check
  namespace: $K8SNS
spec:
  args:
    - name: target_project
    - name: threshold
    - name: mql_query
    - name: checker_image
      value: ${SLOCHECKAPP}
  metrics:
  - name: test
    provider:
      job:
        spec:
          backoffLimit: 1
          template:
            metadata:
              annotations:
                sidecar.istio.io/inject: "false"
            spec:
              serviceAccountName: slo-reader
              restartPolicy: Never
              containers:
              - env:
                - name: TARGET_PROJECT
                  value: {{args.target_project}}
                - name: THRESHOLD
                  value: {{args.threshold}}
                - name: MQL_QUERY
                  value: {{args.mql_query}}
                image: {{args.checker_image}}
                args:
                  - -rmql
                name: ckslo
EOF
cat > 01-services.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${CANARY_SERVICE_NAME}
  namespace: $K8SNS
spec:
  ports:
  - port: 80
    targetPort: http
    protocol: TCP
    name: http
  selector:
    app: rollouts-demo
    # This selector will be updated with the pod-template-hash of the canary ReplicaSet. e.g.:
    # rollouts-pod-template-hash: 7bf84f9696

---
apiVersion: v1
kind: Service
metadata:
  name: ${STABLE_SERVICE_NAME}
  namespace: $K8SNS
spec:
  ports:
  - port: 80
    targetPort: http
    protocol: TCP
    name: http
  selector:
    app: rollouts-demo
    # This selector will be updated with the pod-template-hash of the stable ReplicaSet. e.g.:
    # rollouts-pod-template-hash: 789746c88d
EOF
cat > 02-rollouts-istio.yaml <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: rollouts-demo-gateway
  namespace: $K8SNS
spec:
  selector:
    istio: ingressgateway # use istio default controller
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: rollouts-demo-vsvc
  namespace: $K8SNS
spec:
  gateways:
  - rollouts-demo-gateway
  hosts:
  - rollouts-demo.default.example.com
  http:
  - name: primary
    route:
    - destination:
        host: ${STABLE_SERVICE_NAME}
      weight: 100
    - destination:
        host: ${CANARY_SERVICE_NAME}
      weight: 0

EOF

cat > 03-rollout-initial.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: rollouts-demo
  namespace: $K8SNS
spec:
  replicas: 1
  strategy:
    canary:
      canaryService: ${CANARY_SERVICE_NAME}
      stableService: ${STABLE_SERVICE_NAME}
      trafficRouting:
        istio:
          virtualService:
            name: rollouts-demo-vsvc
            routes:
            - primary # At least one route is required
      steps:
      - setWeight: 5
      - pause:
          duration: 15s
  revisionHistoryLimit: 2
  selector:
    matchLabels:
      app: rollouts-demo
  template:
    metadata:
      labels:
        app: rollouts-demo
        istio-injection: enabled
    spec:
      containers:
      - name: rollouts-demo
        image: $DEMOAPPIMAGE
        ports:
        - name: http
          containerPort: 8080
          protocol: TCP
        resources:
          requests:
            memory: 32Mi
            cpu: 5m
EOF
cat > 04-rollout-yello.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: rollouts-demo
  namespace: $K8SNS
spec:
  replicas: 1
  strategy:
    canary:
      canaryService: ${CANARY_SERVICE_NAME}
      stableService: ${STABLE_SERVICE_NAME}
      trafficRouting:
        istio:
          virtualService:
            name: rollouts-demo-vsvc
            routes:
            - primary # At least one route is required
      steps:
      - setWeight: 10
      - pause: {}
  revisionHistoryLimit: 2
  selector:
    matchLabels:
      app: rollouts-demo
  template:
    metadata:
      labels:
        app: rollouts-demo
        istio-injection: enabled
    spec:
      containers:
      - name: rollouts-demo
        image: $DEMOAPPIMAGE
        args:
          - -cyello
        ports:
        - name: http
          containerPort: 8080
          protocol: TCP
        resources:
          requests:
            memory: 32Mi
            cpu: 5m
EOF
cat > 05-rollout-bad.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: rollouts-demo
spec:
  replicas: 1
  strategy:
    canary:
      canaryService: ${CANARY_SERVICE_NAME}
      stableService: ${STABLE_SERVICE_NAME}
      trafficRouting:
        istio:
          virtualService:
            name: rollouts-demo-vsvc
            routes:
            - primary # At least one route is required
      steps:
      - setWeight: 20
      - pause:
          duration: 300s
      - analysis:
          templates:
          - templateName: gcp-slo-burnrate-check
          args:
          - name: target_project
            value: jscheng-cloudrun
          - name: threshold
            value: "0.5"
          - name: defined_slo
            value: projects/${NUM_PROJECT_ID}/services/${SERVICE_ID}/serviceLevelObjectives/${SLO_ID}
      - setWeight: 40
      - pause:
          duration: 360s
  revisionHistoryLimit: 2
  selector:
    matchLabels:
      app: rollouts-demo
  template:
    metadata:
      labels:
        app: rollouts-demo
        istio-injection: enabled
    spec:
      containers:
      - name: rollouts-demo
        image: $DEMOAPPIMAGE
        args:
          - -cyello
          - -e20
        ports:
        - name: http
          containerPort: 8080
          protocol: TCP
        resources:
          requests:
            memory: 32Mi
            cpu: 5m

EOF
