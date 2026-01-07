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

Set `datasetEnableQuotas: false` in driver config, or downgrade to TrueNAS 24.10.x.

## Root Cause (suspected)

TrueNAS 25.x introduced stricter Pydantic validation for API inputs. The refquota value being sent by democratic-csi may be a string instead of an integer, or in an unexpected format.

## Suggested Fix

Ensure `refquota` is cast to an integer before sending to the TrueNAS API.

```javascript
// In src/driver/freenas/http/api.js (or similar)
// Before:
data.refquota = requiredBytes;

// After:
data.refquota = parseInt(requiredBytes, 10);
```

Or if the value might be a string from config:

```javascript
if (data.refquota) {
  data.refquota = Number(data.refquota);
}
```

## Related Issues

- #479 (TrueNAS 25.04 incompatible)
- #487 (TrueNAS 25.04.0 - zfs and zpool commands not found)
