/// Queue priority. Higher priorities are always dequeued first; equal
/// priorities run in FIFO order.
enum TaskPriority {
  low(0, 'Low'),
  normal(1, 'Normal'),
  high(2, 'High'),
  critical(3, 'Critical');

  const TaskPriority(this.weight, this.displayName);

  /// Numeric weight used for ordering (higher = more urgent).
  final int weight;

  /// Human-readable label.
  final String displayName;

  bool isHigherThan(TaskPriority other) => weight > other.weight;
}
