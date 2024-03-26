#!/bin/bash

make local-setup

kubectl -n kuadrant-system apply -f - <<EOF
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
spec: {}
EOF

kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/addons/jaeger.yaml

kubectl patch -n istio-system istiooperator/istiocontrolplane --type=merge -p '{"spec":{"meshConfig":{"defaultConfig":{"tracing":{}},"enableTracing":true},"values":{"global":{"proxy":{"logLevel": "info"}}}}}'
kubectl patch -n istio-system istiooperator/istiocontrolplane --type=json -p '[{"op": "add", "path": "/spec/meshConfig/extensionProviders/-", "value": {"name": "jaeger-otel","opentelemetry":{"service":"jaeger-collector.istio-system.svc.cluster.local","port":4317}}}]'

kubectl apply -f - <<EOF
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
  name: mesh-default
  namespace: istio-system
spec:
  tracing:
  - providers:
    - name: jaeger-otel
    randomSamplingPercentage: 100
EOF

export INGRESS_HOST=$(kubectl -n istio-system get service istio-ingressgateway-istio -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export INGRESS_DOMAIN=${INGRESS_HOST}.nip.io

kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: jaeger
  namespace: istio-system
spec:
  parentRefs:
  - name: istio-ingressgateway
    namespace: istio-system
  hostnames:
  - tracing.${INGRESS_DOMAIN}
  rules:
  - matches:
    - method: GET
      path:
        type: PathPrefix
        value: "/"
    backendRefs:
    - name: tracing
      port: 80
EOF

kubectl apply -f examples/toystore/toystore.yaml

kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: toystore
spec:
  parentRefs:
  - name: istio-ingressgateway
    namespace: istio-system
  hostnames:
  - api.toystore.com
  rules:
  - matches:
    - method: GET
      path:
        type: PathPrefix
        value: "/cars"
    - method: GET
      path:
        type: PathPrefix
        value: "/dolls"
    backendRefs:
    - name: toystore
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: "/admin"
    backendRefs:
    - name: toystore
      port: 80
EOF

export INGRESS_HOST=$(kubectl get gtw istio-ingressgateway -n istio-system -o jsonpath='{.status.addresses[0].value}')
export INGRESS_PORT=$(kubectl get gtw istio-ingressgateway -n istio-system -o jsonpath='{.spec.listeners[?(@.name=="http")].port}')
export GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT

kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1beta2
kind: AuthPolicy
metadata:
  name: toystore
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: toystore
  rules:
    authentication:
      "api-key-users":
        apiKey:
          selector:
            matchLabels:
              app: toystore
          allNamespaces: true
        credentials:
          authorizationHeader:
            prefix: APIKEY
    response:
      success:
        dynamicMetadata:
          "identity":
            json:
              properties:
                "userid":
                  selector: auth.identity.metadata.annotations.secret\.kuadrant\.io/user-id
EOF

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: bob-key
  labels:
    authorino.kuadrant.io/managed-by: authorino
    app: toystore
  annotations:
    secret.kuadrant.io/user-id: bob
stringData:
  api_key: IAMBOB
type: Opaque
---
apiVersion: v1
kind: Secret
metadata:
  name: alice-key
  labels:
    authorino.kuadrant.io/managed-by: authorino
    app: toystore
  annotations:
    secret.kuadrant.io/user-id: alice
stringData:
  api_key: IAMALICE
type: Opaque
EOF

kubectl patch -n kuadrant-system authorino/authorino --type=merge -p '{"spec":{"tracing":{"endpoint":"rpc://jaeger-collector.istio-system.svc.cluster.local:4317","insecure":true}}}'

kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1beta2
kind: RateLimitPolicy
metadata:
  name: toystore
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: toystore
  limits:
    "alice-limit":
      rates:
      - limit: 5
        duration: 10
        unit: second
      when:
      - selector: metadata.filter_metadata.envoy\.filters\.http\.ext_authz.identity.userid
        operator: eq
        value: alice
    "bob-limit":
      rates:
      - limit: 2
        duration: 10
        unit: second
      when:
      - selector: metadata.filter_metadata.envoy\.filters\.http\.ext_authz.identity.userid
        operator: eq
        value: bob
EOF

echo "Sleeping for 30s while waiting for everything to deploy+configure..."
sleep 30
kubectl scale --replicas=0 deployments/limitador-operator-controller-manager -n kuadrant-system
kubectl wait --timeout=60s --for=condition=Available deployments/limitador-operator-controller-manager -n kuadrant-system
kubectl patch -n kuadrant-system deployment/limitador-limitador --type=json -p '[{"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "quay.io/kuadrant/limitador:tracing-otel"}]'
kubectl patch -n kuadrant-system deployment/limitador-limitador --type=json -p '[{"op": "replace", "path": "/spec/template/spec/containers/0/command", "value": ["limitador-server","--rate-limit-headers","DRAFT_VERSION_03","--limit-name-in-labels","--http-port","8080","--rls-port","8081","-vvv","--tracing-endpoint","rpc://jaeger-collector.istio-system.svc.cluster.local:4317","/home/limitador/etc/limitador-config.yaml","memory"]}]'
