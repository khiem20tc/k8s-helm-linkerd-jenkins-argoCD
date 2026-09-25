package services

import (
	"context"
	"io"
	"sync"
	"testing"

	"user-service/proto"

	"github.com/sirupsen/logrus"
)

func newTestService() *UserService {
	logger := logrus.New()
	logger.SetOutput(io.Discard)
	return NewUserService(logger)
}

func TestCreateUserDoesNotReuseDeletedIDs(t *testing.T) {
	s := newTestService()
	ctx := context.Background()

	if _, err := s.DeleteUser(ctx, &proto.DeleteUserRequest{Id: "1"}); err != nil {
		t.Fatal(err)
	}

	resp, err := s.CreateUser(ctx, &proto.CreateUserRequest{Name: "A", Email: "a@example.com"})
	if err != nil {
		t.Fatal(err)
	}
	if resp.User.Id == "2" {
		t.Fatalf("new user overwrote existing user 2")
	}

	got, _ := s.GetUser(ctx, &proto.GetUserRequest{Id: "2"})
	if !got.Success || got.User.Name != "Jane Smith" {
		t.Fatalf("existing user 2 was modified: %+v", got)
	}
}

func TestCreateUserValidation(t *testing.T) {
	s := newTestService()
	resp, err := s.CreateUser(context.Background(), &proto.CreateUserRequest{Name: "A"})
	if err != nil {
		t.Fatal(err)
	}
	if resp.Success {
		t.Fatal("expected failure when email is missing")
	}
}

func TestListUsersPagination(t *testing.T) {
	s := newTestService()
	ctx := context.Background()

	tests := []struct {
		name      string
		page      int32
		limit     int32
		wantCount int
	}{
		{"zero page and limit use defaults", 0, 0, 2},
		{"negative page", -3, 1, 1},
		{"first page", 1, 1, 1},
		{"second page", 2, 1, 1},
		{"past the end", 5, 1, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resp, err := s.ListUsers(ctx, &proto.ListUsersRequest{Page: tt.page, Limit: tt.limit})
			if err != nil {
				t.Fatal(err)
			}
			if len(resp.Users) != tt.wantCount {
				t.Fatalf("got %d users, want %d", len(resp.Users), tt.wantCount)
			}
			if resp.Total != 2 {
				t.Fatalf("got total %d, want 2", resp.Total)
			}
		})
	}

	// Pages must be stable across calls
	first, _ := s.ListUsers(ctx, &proto.ListUsersRequest{Page: 1, Limit: 1})
	for i := 0; i < 20; i++ {
		again, _ := s.ListUsers(ctx, &proto.ListUsersRequest{Page: 1, Limit: 1})
		if again.Users[0].Id != first.Users[0].Id {
			t.Fatal("pagination order is not stable")
		}
	}
}

func TestConcurrentAccess(t *testing.T) {
	s := newTestService()
	ctx := context.Background()

	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(2)
		go func() {
			defer wg.Done()
			_, _ = s.CreateUser(ctx, &proto.CreateUserRequest{Name: "N", Email: "n@example.com"})
		}()
		go func() {
			defer wg.Done()
			_, _ = s.ListUsers(ctx, &proto.ListUsersRequest{Page: 1, Limit: 10})
		}()
	}
	wg.Wait()

	resp, _ := s.ListUsers(ctx, &proto.ListUsersRequest{Page: 1, Limit: 100})
	if resp.Total != 52 {
		t.Fatalf("got total %d, want 52", resp.Total)
	}
}
