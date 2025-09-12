package handlers

import (
	"context"

	"user-service/proto"
	"user-service/src/services"

	"github.com/sirupsen/logrus"
)

type UserHandler struct {
	proto.UnimplementedUserServiceServer
	userService *services.UserService
	logger      *logrus.Logger
}

func NewUserHandler(userService *services.UserService, logger *logrus.Logger) *UserHandler {
	return &UserHandler{
		userService: userService,
		logger:      logger,
	}
}

func (h *UserHandler) GetUser(ctx context.Context, req *proto.GetUserRequest) (*proto.GetUserResponse, error) {
	h.logger.WithField("user_id", req.Id).Info("Handling GetUser request")
	return h.userService.GetUser(ctx, req)
}

func (h *UserHandler) CreateUser(ctx context.Context, req *proto.CreateUserRequest) (*proto.CreateUserResponse, error) {
	h.logger.WithFields(logrus.Fields{
		"name":  req.Name,
		"email": req.Email,
		"age":   req.Age,
	}).Info("Handling CreateUser request")
	return h.userService.CreateUser(ctx, req)
}

func (h *UserHandler) UpdateUser(ctx context.Context, req *proto.UpdateUserRequest) (*proto.UpdateUserResponse, error) {
	h.logger.WithField("user_id", req.Id).Info("Handling UpdateUser request")
	return h.userService.UpdateUser(ctx, req)
}

func (h *UserHandler) DeleteUser(ctx context.Context, req *proto.DeleteUserRequest) (*proto.DeleteUserResponse, error) {
	h.logger.WithField("user_id", req.Id).Info("Handling DeleteUser request")
	return h.userService.DeleteUser(ctx, req)
}

func (h *UserHandler) ListUsers(ctx context.Context, req *proto.ListUsersRequest) (*proto.ListUsersResponse, error) {
	h.logger.WithFields(logrus.Fields{
		"page":  req.Page,
		"limit": req.Limit,
	}).Info("Handling ListUsers request")
	return h.userService.ListUsers(ctx, req)
}
