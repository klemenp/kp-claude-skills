class AppError(Exception):
    """Base class for application-level errors."""

    def __init__(self, message: str = "") -> None:
        super().__init__(message)
        self.message = message


class NotFoundError(AppError):
    """Raised when a requested resource cannot be found."""


class ConflictError(AppError):
    """Raised when an action conflicts with the current resource state."""


class AuthError(AppError):
    """Raised when authentication or authorization fails."""
