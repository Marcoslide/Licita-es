UPDATE collection_errors
SET retryable=1
WHERE message LIKE '%timed out%' OR message LIKE '%timeout%';
