# TrueNAS Disk Mapping Reference

## Without mSATA Card
Date: 2025-01-07

### Controllers Present:
1. **LSI SAS3008** (04:00.0) - SAS Controller
2. **ASMedia ASM1062** (03:00.0) - SATA Controller  
3. **Intel SATA** (00:1f.2) - Motherboard SATA

### Disk Mapping:

| Device | Size    | Model                     | Serial               | Controller   | Persistent Path |
|--------|---------|---------------------------|----------------------|--------------|-----------------|
| sda    | 5.5T    | ST6000NM0095             | ZAD06G95            | LSI SAS      | `/dev/disk/by-id/scsi-35000c50085f8230f` |
| sdb    | 5.5T    | ST6000NM0095             | ZAD0E58W            | LSI SAS      | `/dev/disk/by-id/scsi-35000c50086437663` |
| sdc    | 5.5T    | ST6000NM0095             | ZAD06XNX            | LSI SAS      | `/dev/disk/by-id/scsi-35000c50085f9a303` |
| sdd    | 232.9G  | Samsung SSD 850 EVO 250GB| S21NNXAG912316R     | ASMedia SATA | `/dev/disk/by-id/ata-Samsung_SSD_850_EVO_250GB_S21NNXAG912316R` |
| sde    | 1.8T    | ST2000DM001-1CH164       | W1E57KPQ            | Intel SATA   | `/dev/disk/by-id/ata-ST2000DM001-1CH164_W1E57KPQ` |
| sdf    | 1.8T    | WDC WD20EFZX-68AWUN0     | WD-WX32DB047SVF     | Intel SATA   | `/dev/disk/by-id/ata-WDC_WD20EFZX-68AWUN0_WD-WX32DB047SVF` |
| sdg    | 5.5T    | ST6000NM0095             | ZAD06TQW            | LSI SAS      | `/dev/disk/by-id/scsi-35000c50085fa336f` |
| sdh    | 119.2G  | M4-CT128M4SSD2           | 000000001307092B0BFC| Intel SATA   | `/dev/disk/by-id/ata-M4-CT128M4SSD2_000000001307092B0BFC` |

### WWN Reference:
- sda: `0x5000c50085f8230f`
- sdb: `0x5000c50086437663`
- sdc: `0x5000c50085f9a303`
- sdd: `0x5002538d4055336d`
- sde: `0x5000c5006a6d53ab`
- sdf: `0x50014ee2be52864e`
- sdg: `0x5000c50085fa336f`
- sdh: `0x500a0751092b0bfc`

## Notes:
- Device names (sda, sdb, etc.) may change between boots
- Use persistent paths `/dev/disk/by-id/` for reliable access
- The mSATA adapter card was not installed during this mapping