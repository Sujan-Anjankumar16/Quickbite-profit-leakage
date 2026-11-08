// Shows where the data came from: Redis (cache hit) or MySQL (cache miss).
export default function Source({ result }) {
  return (
    <span className={`badge ${result.source}`} title={result.key}>
      from {result.source === 'redis' ? `Redis cache (expires in ${result.ttl}s)` : 'MySQL (now cached)'}
    </span>
  );
}
