#!/usr/bin/env ruby

require 'sinatra/base'

module Flapjack
  module Gateways
    class JSONAPI < Sinatra::Base
      module Methods
        module AssociationPost

          def self.registered(app)
            app.helpers Flapjack::Gateways::JSONAPI::Helpers::Headers
            app.helpers Flapjack::Gateways::JSONAPI::Helpers::Miscellaneous

            Flapjack::Gateways::JSONAPI::RESOURCE_CLASSES.each do |resource_class|
              resource = resource_class.short_model_name.plural

              jsonapi_links = if resource_class.respond_to?(:jsonapi_associations)
                resource_class.jsonapi_associations || {}
              else
                {}
              end

              post_links = jsonapi_links.select {|n, jd|
                jd.post.is_a?(TrueClass) && :multiple.eql?(jd.number)
              }

              unless post_links.empty?
                app.class_eval do

                  single = resource.singularize

                  post_links.each_pair do |link_name, link_data|
                    link_type = link_data.type

                    swagger_path "/#{resource}/{#{single}_id}/relationships/#{link_name}" do
                      operation :post do
                        key :description, "Associate one or more #{link_name} to a #{single}"
                        key :operationId, "add_#{single}_#{link_name}"
                        key :consumes, [JSONAPI_MEDIA_TYPE]
                        parameter do
                          key :name, "#{single}_id".to_sym
                          key :in, :path
                          key :description, "Id of a #{single}"
                          key :required, true
                          key :type, :string
                        end
                        parameter do
                          key :name, :data
                          key :in, :body
                          key :description, "#{link_name} to associate with the #{single}"
                          key :required, true
                          schema do
                            key :type, :array
                            items do
                              key :"$ref", "#{link_type}Reference".to_sym
                            end
                          end
                        end
                        response 204 do
                          key :description, ''
                        end
                        # response :default do
                        #   key :description, 'unexpected error'
                        #   schema do
                        #     key :'$ref', :ErrorModel
                        #   end
                        # end
                      end
                    end
                  end
                end

              end

              id_patt = if Flapjack::Data::Tag.eql?(resource_class)
                "\\S+"
              else
                Flapjack::UUID_RE
              end

              app.post %r{^/#{resource}/(#{id_patt})/relationships/(.+)$} do
                resource_id = params[:captures][0]
                assoc_name  = params[:captures][1].to_sym

                halt(404) unless post_links.has_key?(assoc_name)

                status 204

                assoc = post_links[assoc_name.to_sym]

                assoc_ids, _ = wrapped_link_params(:association => assoc)

                halt(err(403, 'No link ids')) if assoc_ids.empty?
                resource_class.lock(*assoc.lock_klasses) do
                  # Not checking for duplication on adding existing to a multiple
                  # association, the JSONAPI spec doesn't ask for it
                  resource_obj = resource_class.find_by_id!(resource_id)
                  resource_obj.send(assoc_name.to_sym).add_ids(*assoc_ids)
                end
              end
            end
          end
        end
      end
    end
  end
end
