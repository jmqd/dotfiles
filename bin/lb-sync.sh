aws s3 cp --recursive ~/logbook/ s3://$PERSONAL_AWS_BUCKET/logbook/
aws s3 sync s3://${PERSONAL_AWS_BUCKET}/logbook ~/logbook
