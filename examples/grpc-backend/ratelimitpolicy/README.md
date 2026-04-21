# RateLimitPolicy for GRPCRoute

Examples demonstrating how to rate limit gRPC services using Kuadrant's RateLimitPolicy attached to a GRPCRoute.

## Prerequisites

A Gateway must exist for the GRPCRoute to attach to. The GRPCRoute in this example references the `kuadrant-ingressgateway` Gateway in the `gateway-system` namespace, which is created by `make local-setup`.

Deploy the Kuadrant resource:

```bash
kubectl apply -f examples/grpc-backend/kuadrant.yaml
```

Deploy the grpcbin backend and GRPCRoute:

```bash
kubectl apply -f examples/grpc-backend/grpcbin.yaml
kubectl apply -f examples/grpc-backend/grpcroute.yaml
```

Obtain the Gateway IP:

```bash
export GATEWAY_IP=$(kubectl get svc -n gateway-system kuadrant-ingressgateway-istio -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

## Example 1: Basic Rate Limiting

### Deploy

```bash
kubectl apply -f examples/grpc-backend/ratelimitpolicy/ratelimitpolicy.yaml
```

### Verify Policy Status

```bash
kubectl get ratelimitpolicy grpcbin-rlp -o wide
```

Wait for `Accepted` and `Enforced` conditions to be `True`.

### Test

Make repeated requests to trigger the rate limit (10 requests per 10 seconds):

```bash
for i in {1..15}; do
  echo "Request $i:"
  grpcurl -plaintext -authority grpcbin.local \
    -d '{"f_string": "hello"}' \
    $GATEWAY_IP:80 grpcbin.GRPCBin/DummyUnary
  sleep 0.5
done
```

**Note on gRPC Reflection and Rate Limiting:**

When testing with `grpcurl`, you may observe fewer successful requests than the configured limit suggests. This is because `grpcurl` uses gRPC reflection by default, which makes additional gRPC calls to discover service definitions before invoking your actual method. The rate limit applies to **all gRPC traffic**, including these reflection calls.

For example, with a limit of 10 requests per 10 seconds:
- Each `grpcurl` invocation makes ~2-3 gRPC calls (reflection + actual method)
- You'll see approximately 3-5 successful `grpcurl` invocations before hitting the rate limit
- This means only ~3-5 of your 15 test requests will succeed, not all 10
- Production gRPC clients compile `.proto` files and don't use reflection, so they only count actual method calls

**Recommended: Excluding Reflection from Rate Limits**

The recommended approach for testing is to configure the rate limit to only apply to actual gRPC method calls, excluding reflection requests. This makes test results match the configured limit exactly.

First, remove any existing policies, then deploy the no-reflection policy:

```bash
kubectl delete -f examples/grpc-backend/ratelimitpolicy/ 2>/dev/null || true
kubectl apply -f examples/grpc-backend/ratelimitpolicy/ratelimitpolicy-no-reflection.yaml
```

This policy uses a CEL predicate to exclude paths starting with `/grpc.reflection.`:

```yaml
when:
- predicate: "!request.path.startsWith('/grpc.reflection.')"
```

Now when you test:
```bash
for i in {1..12}; do
  echo "Request $i:"
  grpcurl -plaintext -authority grpcbin.local \
    -d '{"f_string": "hello"}' \
    $GATEWAY_IP:80 grpcbin.GRPCBin/DummyUnary
  sleep 0.5
done
```

Expected: 10 successful `grpcurl` invocations (reflection calls excluded), then requests 11-12 return `Code: Unavailable` (rate limited). This matches the configured limit exactly, making testing predictable.

## Example 2: Method-Specific Rate Limits

This example demonstrates using CEL predicates to apply different rate limits to different gRPC methods.

### Deploy

Remove any existing RateLimitPolicies from previous examples:

```bash
kubectl delete -f examples/grpc-backend/ratelimitpolicy/ 2>/dev/null || true
```

Then deploy the method-specific policy:

```bash
kubectl apply -f examples/grpc-backend/ratelimitpolicy/ratelimitpolicy-method.yaml
```

This policy applies different limits based on the gRPC method:
- `DummyUnary`: 5 requests per 10 seconds
- `HeadersUnary`: 2 requests per 10 seconds

### Verify Policy Status

```bash
kubectl get ratelimitpolicy grpcbin-method-rlp -o wide
```

Wait for `Accepted` and `Enforced` conditions to be `True`.

### Test

**Test DummyUnary limit (5 requests per 10s):**

```bash
for i in {1..8}; do
  echo "Request $i:"
  grpcurl -plaintext -authority grpcbin.local \
    -d '{"f_string": "hello"}' \
    $GATEWAY_IP:80 grpcbin.GRPCBin/DummyUnary
  sleep 1
done
```

Expected: 5 successful invocations, then `Code: Unavailable` from request 6 onwards. Reflection calls are not affected by this limit since the `when` predicate only matches `/grpcbin.GRPCBin/DummyUnary`.

**Test HeadersUnary limit (2 requests per 10s):**

```bash
for i in {1..5}; do
  echo "Request $i:"
  grpcurl -plaintext -authority grpcbin.local \
    $GATEWAY_IP:80 grpcbin.GRPCBin/HeadersUnary
  sleep 1
done
```

Expected: 2 successful invocations, then `Code: Unavailable` from request 3 onwards. Reflection calls are not affected since the `when` predicate only matches `/grpcbin.GRPCBin/HeadersUnary`.

## Cleanup

```bash
kubectl delete -f examples/grpc-backend/ratelimitpolicy/ 2>/dev/null || true
```

## Notes

- **gRPC Reflection Impact**: Tools like `grpcurl` use gRPC reflection by default, making 2-3 additional gRPC calls per invocation to discover service definitions. Rate limits apply to all gRPC traffic, including reflection calls. Production gRPC clients compile `.proto` files and don't use reflection, so they only count actual method calls against the rate limit.
- **Recommended Testing Approach**: Use the `ratelimitpolicy-no-reflection.yaml` example to exclude gRPC reflection calls from rate limits. This makes test results predictable and match the configured limits exactly.
- **Method-Specific Limits**: Use `when` predicates with CEL expressions to apply different rate limits to different gRPC methods. The `request.path` selector contains the full gRPC path (e.g., `/grpcbin.GRPCBin/DummyUnary`).
- **Gateway-level Policies**: RateLimitPolicies can be attached to Gateways as defaults that apply to all GRPCRoutes, with route-level policies overriding them.
