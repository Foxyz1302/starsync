enum HealthSeverity { ok, info, warn, error }

class HealthStatus {
  final HealthSeverity severity;
  final String message;
  const HealthStatus(this.severity, this.message);
}
