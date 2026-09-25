package services

import (
	"context"
	"math"
	"sort"
	"strconv"
	"sync"
	"time"

	"user-service/proto"

	"github.com/sirupsen/logrus"
)

type User struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Email     string    `json:"email"`
	Age       int32     `json:"age"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

const (
	defaultPageSize = 10
	maxPageSize     = 100
)

type UserService struct {
	logger *logrus.Logger

	mu     sync.RWMutex
	users  map[string]*User
	nextID int
}

func NewUserService(logger *logrus.Logger) *UserService {
	service := &UserService{
		logger: logger,
		users:  make(map[string]*User),
	}

	// Initialize with some sample data
	service.initializeSampleData()

	return service
}

func (s *UserService) initializeSampleData() {
	sampleUsers := []*User{
		{
			ID:        "1",
			Name:      "John Doe",
			Email:     "john.doe@example.com",
			Age:       30,
			CreatedAt: time.Now().Add(-24 * time.Hour),
			UpdatedAt: time.Now().Add(-24 * time.Hour),
		},
		{
			ID:        "2",
			Name:      "Jane Smith",
			Email:     "jane.smith@example.com",
			Age:       25,
			CreatedAt: time.Now().Add(-12 * time.Hour),
			UpdatedAt: time.Now().Add(-12 * time.Hour),
		},
	}

	for _, user := range sampleUsers {
		s.users[user.ID] = user
	}
	s.nextID = len(sampleUsers)

	s.logger.Info("Initialized sample user data")
}

func (s *UserService) GetUser(ctx context.Context, req *proto.GetUserRequest) (*proto.GetUserResponse, error) {
	s.logger.WithField("user_id", req.Id).Info("Getting user")

	s.mu.RLock()
	defer s.mu.RUnlock()

	user, exists := s.users[req.Id]
	if !exists {
		return &proto.GetUserResponse{
			Success: false,
			Message: "User not found",
		}, nil
	}

	return &proto.GetUserResponse{
		User:    s.convertToProtoUser(user),
		Success: true,
		Message: "User retrieved successfully",
	}, nil
}

func (s *UserService) CreateUser(ctx context.Context, req *proto.CreateUserRequest) (*proto.CreateUserResponse, error) {
	s.logger.WithFields(logrus.Fields{
		"name":  req.Name,
		"email": req.Email,
		"age":   req.Age,
	}).Info("Creating user")

	if req.Name == "" || req.Email == "" {
		return &proto.CreateUserResponse{
			Success: false,
			Message: "Name and email are required",
		}, nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	// Monotonic ID so deleted IDs are never reused (in production, use UUID)
	s.nextID++
	userID := strconv.Itoa(s.nextID)

	now := time.Now()
	user := &User{
		ID:        userID,
		Name:      req.Name,
		Email:     req.Email,
		Age:       req.Age,
		CreatedAt: now,
		UpdatedAt: now,
	}

	s.users[userID] = user

	return &proto.CreateUserResponse{
		User:    s.convertToProtoUser(user),
		Success: true,
		Message: "User created successfully",
	}, nil
}

func (s *UserService) UpdateUser(ctx context.Context, req *proto.UpdateUserRequest) (*proto.UpdateUserResponse, error) {
	s.logger.WithField("user_id", req.Id).Info("Updating user")

	s.mu.Lock()
	defer s.mu.Unlock()

	user, exists := s.users[req.Id]
	if !exists {
		return &proto.UpdateUserResponse{
			Success: false,
			Message: "User not found",
		}, nil
	}

	// Update fields if provided
	if req.Name != "" {
		user.Name = req.Name
	}
	if req.Email != "" {
		user.Email = req.Email
	}
	if req.Age > 0 {
		user.Age = req.Age
	}
	user.UpdatedAt = time.Now()

	return &proto.UpdateUserResponse{
		User:    s.convertToProtoUser(user),
		Success: true,
		Message: "User updated successfully",
	}, nil
}

func (s *UserService) DeleteUser(ctx context.Context, req *proto.DeleteUserRequest) (*proto.DeleteUserResponse, error) {
	s.logger.WithField("user_id", req.Id).Info("Deleting user")

	s.mu.Lock()
	defer s.mu.Unlock()

	_, exists := s.users[req.Id]
	if !exists {
		return &proto.DeleteUserResponse{
			Success: false,
			Message: "User not found",
		}, nil
	}

	delete(s.users, req.Id)

	return &proto.DeleteUserResponse{
		Success: true,
		Message: "User deleted successfully",
	}, nil
}

func (s *UserService) ListUsers(ctx context.Context, req *proto.ListUsersRequest) (*proto.ListUsersResponse, error) {
	s.logger.WithFields(logrus.Fields{
		"page":  req.Page,
		"limit": req.Limit,
	}).Info("Listing users")

	page := int(req.Page)
	if page < 1 {
		page = 1
	}
	limit := int(req.Limit)
	if limit < 1 {
		limit = defaultPageSize
	}
	if limit > maxPageSize {
		limit = maxPageSize
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	allUsers := make([]*User, 0, len(s.users))
	for _, user := range s.users {
		allUsers = append(allUsers, user)
	}

	// Map iteration order is random; sort so pages are stable
	sort.Slice(allUsers, func(i, j int) bool {
		if !allUsers[i].CreatedAt.Equal(allUsers[j].CreatedAt) {
			return allUsers[i].CreatedAt.Before(allUsers[j].CreatedAt)
		}
		return allUsers[i].ID < allUsers[j].ID
	})

	// Apply pagination
	start := (page - 1) * limit
	end := start + limit

	if start >= len(allUsers) {
		return &proto.ListUsersResponse{
			Users:   []*proto.User{},
			Total:   toInt32(len(allUsers)),
			Success: true,
			Message: "No users found for the given page",
		}, nil
	}

	if end > len(allUsers) {
		end = len(allUsers)
	}

	paginatedUsers := allUsers[start:end]
	protoUsers := make([]*proto.User, len(paginatedUsers))
	for i, user := range paginatedUsers {
		protoUsers[i] = s.convertToProtoUser(user)
	}

	return &proto.ListUsersResponse{
		Users:   protoUsers,
		Total:   toInt32(len(allUsers)),
		Success: true,
		Message: "Users retrieved successfully",
	}, nil
}

func (s *UserService) convertToProtoUser(user *User) *proto.User {
	return &proto.User{
		Id:        user.ID,
		Name:      user.Name,
		Email:     user.Email,
		Age:       user.Age,
		CreatedAt: user.CreatedAt.Format(time.RFC3339),
		UpdatedAt: user.UpdatedAt.Format(time.RFC3339),
	}
}

// toInt32 converts n to int32, clamping values that do not fit.
func toInt32(n int) int32 {
	if n > math.MaxInt32 {
		return math.MaxInt32
	}
	if n < math.MinInt32 {
		return math.MinInt32
	}
	return int32(n)
}
