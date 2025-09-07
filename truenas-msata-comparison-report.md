# TrueNAS mSATA Card Installation Report
Date: 2025-01-07

## Summary
**❌ mSATA drive is NOT detected**

Despite installing the mSATA PCIe adapter card, no new drive appears in the system. The mSATA adapter card itself is not showing up as a separate PCIe device.

## PCIe Controllers Comparison

### Before (without mSATA card):
1. Intel SATA (00:1f.2) - Motherboard
2. ASMedia ASM1062 (03:00.0) - PCIe SATA card
3. LSI SAS3008 (04:00.0) - SAS controller

### After (with mSATA card):
1. Intel SATA (00:1f.2) - Motherboard
2. ASMedia ASM1062 (03:00.0) - PCIe SATA card
3. LSI SAS3008 (04:00.0) - SAS controller

**Result:** No new PCIe device detected

## Disk Mapping Comparison

### Drive Count:
- **Before:** 8 drives (sda through sdh)
- **After:** 8 drives (sda through sdh)
- **New drives:** 0

### Drive Reassignment (same drives, different device names):

| Serial | Model | Size | Before | After | Controller |
|--------|-------|------|--------|-------|------------|
| ZAD06TQW | ST6000NM0095 | 5.5T | sdg | **sda** | LSI SAS |
| 000000001307092B0BFC | M4-CT128M4SSD2 | 119.2G | sdh | **sdb** | Intel SATA |
| ZAD06G95 | ST6000NM0095 | 5.5T | sda | **sdc** | LSI SAS |
| ZAD06XNX | ST6000NM0095 | 5.5T | sdc | **sdd** | LSI SAS |
| WD-WX32DB047SVF | WDC WD20EFZX | 1.8T | sdf | **sde** | Intel SATA |
| S21NNXAG912316R | Samsung 850 EVO | 232.9G | sdd | **sdf** | ASMedia SATA |
| ZAD0E58W | ST6000NM0095 | 5.5T | sdb | **sdg** | LSI SAS |
| W1E57KPQ | ST2000DM001 | 1.8T | sde | **sdh** | Intel SATA |

## ASMedia Controller Status
- The ASMedia ASM1062 controller at 03:00.0 is only controlling one drive: Samsung 850 EVO (now sdf)
- No second drive detected on this controller
- This appears to be a separate SATA PCIe card, NOT the mSATA adapter

## Troubleshooting Possibilities

### The mSATA adapter card is not being detected. Possible causes:

1. **PCIe Slot Issue**
   - Try a different PCIe slot
   - Ensure card is fully seated

2. **Power Issue**
   - The 2-pin connector on the card might need external 5V power
   - Some mSATA drives require more power than PCIe slot provides

3. **Compatibility Issue**
   - The mSATA adapter might not be compatible with your system
   - BIOS/UEFI might need PCIe configuration changes

4. **Card/Drive Failure**
   - The mSATA adapter card itself might be defective
   - Both mSATA drives you tried might be dead

5. **Wrong Adapter Type**
   - Verify the adapter is actually a PCIe-to-mSATA adapter
   - Some adapters are passive and meant to be used with specific motherboard connectors

## Recommendations

1. **Check BIOS/UEFI settings** for PCIe slot configuration
2. **Try a different PCIe slot** if available
3. **Provide external 5V power** to the 2-pin connector if you have a suitable power source
4. **Verify the adapter model** to ensure it's a standalone PCIe card and not a passive adapter
5. **Test the mSATA drives** in another system if possible to verify they work