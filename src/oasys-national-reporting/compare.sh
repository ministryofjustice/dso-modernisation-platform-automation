#!/bin/bash
# Check ncr_control and onr_control are aligned
echo "### control ###"
diff $@  <(sed s/NCR/ONR/g ../nomis-combined-reporting/ncr_control.sh | sed 's/nomis-combined/oasys-national/g' | sed 's/t1/t2/g' | sed 's/ncr/onr/g') onr_control.sh
cd ../../.github/workflows
echo
echo "### start ###"
diff <(sed s/NCR/ONR/g ncr_environment_start.yml | sed 's/nomis-combined/oasys-national/g' | sed 's/t1/t2/g' | sed 's/ncr/onr/g') onr_environment_start.yml
echo
echo "### stop ###"
diff <(sed s/NCR/ONR/g ncr_environment_stop.yml | sed 's/nomis-combined/oasys-national/g' | sed 's/t1/t2/g' | sed 's/ncr/onr/g') onr_environment_stop.yml
