// The closed set of error codes (K5). Anything thrown without one surfaces as INTERNAL.
export type ErrorCode =
  | 'NO_COMMAND'
  | 'UNKNOWN_COMMAND'
  | 'INVALID_ARGS'
  | 'ADB_NOT_FOUND'
  | 'ADB_TIMEOUT'
  | 'ADB_FAILED'
  | 'SIMCTL_NOT_FOUND'
  | 'SIMCTL_TIMEOUT'
  | 'SIMCTL_FAILED'
  | 'NO_DEVICE'
  | 'DEVICE_NOT_FOUND'
  | 'DEVICE_AMBIGUOUS'
  | 'DEVICE_NOT_READY'
  | 'CAPTURE_FAILED'
  | 'AUTOMATION_BUSY'
  | 'WRITE_FAILED'
  | 'TEXT_UNSUPPORTED'
  | 'ELEMENT_NOT_FOUND'
  | 'ELEMENT_AMBIGUOUS'
  | 'ELEMENT_COVERED'
  | 'INPUT_BLOCKED'
  | 'INSTALL_FAILED'
  | 'UNINSTALL_FAILED'
  | 'APP_NOT_FOUND'
  | 'APP_NOT_LAUNCHABLE'
  | 'HELPER_FAILED'
  | 'NOT_SUPPORTED'
  | 'INTERNAL';

export class KaragozError extends Error {
  constructor(
    readonly code: ErrorCode,
    message: string,
    // Android's own code for INSTALL_FAILED and UNINSTALL_FAILED, such as INSTALL_FAILED_VERSION_DOWNGRADE (K5, K28).
    readonly reason?: string,
  ) {
    super(message);
  }
}
