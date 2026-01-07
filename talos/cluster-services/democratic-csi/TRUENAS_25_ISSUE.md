# TrueNAS 25.x: refquota API validation fails with Pydantic error

## Description

After upgrading to TrueNAS 25.10.1, PVC provisioning fails when `datasetEnableQuotas: true` is set. The TrueNAS API rejects the refquota value with a Pydantic validation error.

## Error

```
failed to provision volume with StorageClass "nfs": rpc error: code = Internal desc = Error:
{"data.refquota.constrained-int":[{"message":"Input should be a valid integer","errno":22}],
"data.refquota.literal[0,None]":[{"message":"Input should be 0 or None","errno":22}],
"data.refquota.is-instance[_NotRequired]":[{"message":"Input should be an instance of _NotRequired","errno":22}]}
```

## Environment

- **TrueNAS version:** 25.10.1 (also likely affects 25.04+)
- **democratic-csi image:** `democraticcsi/democratic-csi:next`
- **Driver:** `freenas-api-nfs`
- **apiVersion:** 2

## Reproduction

1. Configure democratic-csi with `datasetEnableQuotas: true`
2. Create a PVC using the NFS storage class
3. Observe the Pydantic validation error in controller logs

## Workaround

Downgrade to TrueNAS 24.10.x.

## Root Cause

TrueNAS 25.x introduced stricter Pydantic validation for API inputs. In `src/driver/freenas/api.js`, the CreateVolume method sets:

```javascript
if (this.options.zfs.datasetEnableQuotas) {
  setProps = true;
  properties.refquota = capacity_bytes;
}
```

Where `capacity_bytes` comes from:

```javascript
let capacity_bytes =
  call.request.capacity_range.required_bytes ||
  call.request.capacity_range.limit_bytes;
```

The CSI GRPC uses protobuf int64 values which may be represented as strings or BigInt in JavaScript. TrueNAS 25.x now strictly validates that `refquota` is an integer.

## Suggested Fix

In `src/driver/freenas/api.js`, explicitly convert to Number before setting refquota:

```javascript
if (this.options.zfs.datasetEnableQuotas) {
  setProps = true;
  properties.refquota = Number(capacity_bytes);
}
```

The same fix should apply to `refreservation` if `datasetEnableReservation` is used.

## Related Issues

- #479 (TrueNAS 25.04 incompatible)
- #487 (TrueNAS 25.04.0 - zfs and zpool commands not found)
