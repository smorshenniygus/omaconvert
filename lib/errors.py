class OmaConvertError(Exception):
    def __init__(self, message, details=""):
        super().__init__(message)
        self.message = message
        self.details = details


class Cancelled(OmaConvertError):
    pass


class ProcessFailed(OmaConvertError):
    pass

