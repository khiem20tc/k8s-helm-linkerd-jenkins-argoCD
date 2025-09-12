package main

import (
	"context"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"user-service/proto"
	"user-service/src/handlers"
	"user-service/src/services"

	"github.com/gin-gonic/gin"
	"github.com/sirupsen/logrus"
	"github.com/spf13/viper"
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"
)

func main() {
	// Initialize configuration
	initConfig()

	// Initialize logger
	logger := logrus.New()
	logger.SetFormatter(&logrus.JSONFormatter{})
	logger.SetLevel(logrus.InfoLevel)

	// Initialize services
	userService := services.NewUserService(logger)

	// Start gRPC server
	grpcServer := startGRPCServer(userService, logger)
	
	// Start HTTP server for health checks and metrics
	httpServer := startHTTPServer(logger)

	// Wait for interrupt signal to gracefully shutdown the servers
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	logger.Info("Shutting down servers...")

	// Graceful shutdown
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	grpcServer.GracefulStop()
	
	if err := httpServer.Shutdown(ctx); err != nil {
		logger.Fatal("HTTP server forced to shutdown:", err)
	}

	logger.Info("Servers exited")
}

func initConfig() {
	viper.SetDefault("grpc.port", "50051")
	viper.SetDefault("http.port", "8080")
	viper.SetDefault("log.level", "info")
	
	viper.SetConfigName("config")
	viper.SetConfigType("yaml")
	viper.AddConfigPath("./configs")
	viper.AddConfigPath(".")
	
	if err := viper.ReadInConfig(); err != nil {
		log.Printf("Warning: Could not read config file: %v", err)
	}
}

func startGRPCServer(userService *services.UserService, logger *logrus.Logger) *grpc.Server {
	port := viper.GetString("grpc.port")
	lis, err := net.Listen("tcp", ":"+port)
	if err != nil {
		logger.Fatalf("Failed to listen on port %s: %v", port, err)
	}

	grpcServer := grpc.NewServer()
	
	// Register services
	proto.RegisterUserServiceServer(grpcServer, handlers.NewUserHandler(userService, logger))
	
	// Enable reflection for debugging
	reflection.Register(grpcServer)

	logger.Infof("gRPC server listening on port %s", port)
	
	go func() {
		if err := grpcServer.Serve(lis); err != nil {
			logger.Fatalf("Failed to serve gRPC: %v", err)
		}
	}()

	return grpcServer
}

func startHTTPServer(logger *logrus.Logger) *gin.Engine {
	port := viper.GetString("http.port")
	
	gin.SetMode(gin.ReleaseMode)
	router := gin.New()
	router.Use(gin.Logger(), gin.Recovery())

	// Health check endpoint
	router.GET("/health", func(c *gin.Context) {
		c.JSON(200, gin.H{
			"status": "healthy",
			"timestamp": time.Now().UTC(),
			"service": "user-service",
		})
	})

	// Metrics endpoint
	router.GET("/metrics", func(c *gin.Context) {
		c.JSON(200, gin.H{
			"requests_total": 0,
			"uptime": time.Since(time.Now()).String(),
		})
	})

	// Readiness probe
	router.GET("/ready", func(c *gin.Context) {
		c.JSON(200, gin.H{
			"status": "ready",
		})
	})

	logger.Infof("HTTP server listening on port %s", port)
	
	go func() {
		if err := router.Run(":" + port); err != nil {
			logger.Fatalf("Failed to start HTTP server: %v", err)
		}
	}()

	return router
}
