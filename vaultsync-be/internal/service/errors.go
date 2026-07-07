package service

import (
	"errors"
	"net/http"
)

const (
	CodeInvalidRequest = "invalid_request"
	CodeUnauthorized   = "unauthorized"
	CodeForbidden      = "forbidden"
	CodeNotFound       = "not_found"
	CodeInternal       = "internal_error"
)

type AppError struct {
	Code    string
	Message string
	Status  int
}

func (e AppError) Error() string {
	return e.Message
}

func InvalidRequest(message string) error {
	return AppError{Code: CodeInvalidRequest, Message: message, Status: http.StatusBadRequest}
}

func Unauthorized(message string) error {
	return AppError{Code: CodeUnauthorized, Message: message, Status: http.StatusUnauthorized}
}

func Forbidden(message string) error {
	return AppError{Code: CodeForbidden, Message: message, Status: http.StatusForbidden}
}

func NotFound(message string) error {
	return AppError{Code: CodeNotFound, Message: message, Status: http.StatusNotFound}
}

func ToAppError(err error) AppError {
	var appErr AppError
	if errors.As(err, &appErr) {
		return appErr
	}
	return AppError{Code: CodeInternal, Message: "internal server error", Status: http.StatusInternalServerError}
}
